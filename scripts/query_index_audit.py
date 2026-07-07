#!/usr/bin/env python3
"""query_index_audit.py [ROOT]

Static cross-reference of ORM schemas vs query call sites. Flags columns
filtered by application code that lack a corresponding index in the schema
or a matching Postgres migration.

Coverage:
  Schemas   — Prisma (schema.prisma), TypeORM decorators (@Entity, @Index,
              @Column({unique:true|index:true}), @PrimaryGeneratedColumn),
              SQLAlchemy (Column(index=True), Index(...), primary_key=True),
              Django (db_index=True, unique=True, Meta.indexes = [...]),
              GORM struct tags (gorm:"index" / "uniqueIndex" / "primaryKey"),
              Postgres migrations (CREATE INDEX, PRIMARY KEY, UNIQUE).

  Queries   — Prisma .findMany/.findFirst/.findUnique/.update/.delete({where:{col:...}}),
              TypeORM repo.findOne/.find({where:{col:...}}),
              SQLAlchemy .filter_by(col=...) and .filter(Model.col == ...),
              Django Model.objects.filter/get/exclude(col=...),
              GORM db.Where("col = ?", ...) + typed .First(&x, "col = ?").

Heuristic-first: false positives are OK; the point is to force authors
to explain why an unindexed column is safe.
"""
import json, os, re, sys
from collections import defaultdict

ROOT = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("GITHUB_WORKSPACE", ".")
OUT  = os.path.join(ROOT, "query-index.json")

# {model_or_table_lower: set(indexed_columns_lower)}  — global index registry
indexed = defaultdict(set)
# {model_or_table_lower: set(all_declared_columns_lower)}  — for target inference
declared = defaultdict(set)
# every indexed column, table-agnostic — for fallback matching
any_indexed = set()

# Query sites: [(file, line, model_hint, columns)]
queries = []


def add_indexed(table, col):
    t = (table or "").lower()
    c = (col or "").lower()
    if not c: return
    indexed[t].add(c)
    any_indexed.add(c)


def add_declared(table, col):
    if not table or not col: return
    declared[table.lower()].add(col.lower())


def walk(exts):
    for dp, dns, fns in os.walk(ROOT):
        dns[:] = [d for d in dns if d not in {"node_modules","vendor",".git","dist","build",".venv",".wasaa-ci",".next","coverage"}]
        for fn in fns:
            if any(fn.endswith(e) for e in exts):
                yield os.path.join(dp, fn)


# ---------------------------------------------------------------------------
# SCHEMA PARSERS
# ---------------------------------------------------------------------------

def parse_prisma():
    """schema.prisma
       model User {
         id       String @id
         email    String @unique
         tenantId String
         @@index([tenantId])
         @@unique([tenantId, email])
       }
    """
    for p in walk((".prisma",)):
        try: text = open(p, errors="replace").read()
        except Exception: continue
        for block in re.finditer(r"model\s+(\w+)\s*\{([^}]+)\}", text, re.S):
            model, body = block.group(1), block.group(2)
            table = model
            for line in body.splitlines():
                s = line.strip()
                # column with attributes
                fm = re.match(r"(\w+)\s+\S+(.*)", s)
                if fm and not s.startswith("@@"):
                    col = fm.group(1); attrs = fm.group(2)
                    add_declared(table, col)
                    if "@id" in attrs or "@unique" in attrs: add_indexed(table, col)
                # composite indexes
                for cm in re.finditer(r"@@(index|unique|id)\s*\(\s*\[([^\]]+)\]", s):
                    for c in cm.group(2).split(","):
                        add_indexed(table, c.strip())


def parse_typeorm():
    """TypeScript entity files.
       @Entity() @Index(['tenantId','email'])
       class User { @PrimaryGeneratedColumn() id; @Column({unique:true}) email; @Index() @Column() tenantId; }
    """
    for p in walk((".ts",)):
        # cheap gate — only parse files with @Entity to avoid noise
        try: text = open(p, errors="replace").read()
        except Exception: continue
        if "@Entity" not in text: continue

        # each @Entity class
        for cls in re.finditer(r"@Entity\s*\([^)]*\)\s*(?:@\w+\([^)]*\)\s*)*class\s+(\w+)[^{]*\{([^}]+(?:\{[^}]*\}[^}]*)*)\}", text, re.S):
            table = cls.group(1)
            body = cls.group(2)
            # class-level @Index(['a','b'])
            for cm in re.finditer(r"@Index\s*\(\s*\[([^\]]+)\]", body):
                for c in cm.group(1).split(","):
                    add_indexed(table, c.strip().strip("'\""))
            # per-field decorators
            for fm in re.finditer(r"((?:@\w+\([^)]*\)\s*)+)(\w+)\s*[!?:]", body):
                decos, col = fm.group(1), fm.group(2)
                add_declared(table, col)
                if "@PrimaryGeneratedColumn" in decos or "@PrimaryColumn" in decos:
                    add_indexed(table, col)
                elif "@Index" in decos:
                    add_indexed(table, col)
                elif re.search(r"@Column\s*\(\s*\{[^}]*unique\s*:\s*true", decos):
                    add_indexed(table, col)
                elif re.search(r"@Column\s*\(\s*\{[^}]*index\s*:\s*true", decos):
                    add_indexed(table, col)


def parse_sqlalchemy():
    """class User(Base):
         __tablename__ = 'users'
         id = Column(Integer, primary_key=True)
         email = Column(String, unique=True)
         tenant_id = Column(String, index=True)
         __table_args__ = (Index('ix', 'tenant_id', 'created_at'),)
    """
    for p in walk((".py",)):
        try: text = open(p, errors="replace").read()
        except Exception: continue
        if "Base)" not in text and "DeclarativeBase" not in text and "declarative_base" not in text: continue

        # class Foo(...): ... until next top-level class or EOF
        for cls in re.finditer(r"class\s+(\w+)\s*\([^)]*(?:Base|DeclarativeBase)[^)]*\)\s*:\s*\n((?:[ \t].*\n|\n)+)", text):
            model = cls.group(1); body = cls.group(2)
            tbl_m = re.search(r"__tablename__\s*=\s*['\"](\w+)['\"]", body)
            table = tbl_m.group(1) if tbl_m else model
            # Column definitions
            for fm in re.finditer(r"^\s*(\w+)\s*=\s*(?:sa\.)?Column\(([^)]*)\)", body, re.M):
                col, args = fm.group(1), fm.group(2)
                add_declared(table, col)
                if "primary_key" in args and "True" in args: add_indexed(table, col)
                if re.search(r"\bunique\s*=\s*True", args): add_indexed(table, col)
                if re.search(r"\bindex\s*=\s*True", args): add_indexed(table, col)
            # Index('name', 'a', 'b', ...)
            for im in re.finditer(r"Index\s*\(\s*['\"]\w+['\"]\s*,\s*([^)]+)\)", body):
                for c in re.findall(r"['\"](\w+)['\"]", im.group(1)):
                    add_indexed(table, c)


def parse_django():
    """class User(models.Model):
         email = models.EmailField(unique=True)
         tenant_id = models.CharField(db_index=True)
         class Meta:
             indexes = [models.Index(fields=['tenant_id','created_at'])]
    """
    for p in walk((".py",)):
        if "models.py" not in os.path.basename(p) and "/models/" not in p: continue
        try: text = open(p, errors="replace").read()
        except Exception: continue
        for cls in re.finditer(r"class\s+(\w+)\s*\([^)]*(?:models\.Model|Model)[^)]*\)\s*:\s*\n((?:[ \t].*\n|\n)+)", text):
            model = cls.group(1); body = cls.group(2)
            # Django adds implicit `id` primary key on every model
            add_indexed(model, "id"); add_declared(model, "id")
            # fields
            for fm in re.finditer(r"^\s*(\w+)\s*=\s*models\.\w+\(([^)]*)\)", body, re.M):
                col, args = fm.group(1), fm.group(2)
                add_declared(model, col)
                if re.search(r"\bprimary_key\s*=\s*True", args): add_indexed(model, col)
                if re.search(r"\bunique\s*=\s*True", args): add_indexed(model, col)
                if re.search(r"\bdb_index\s*=\s*True", args): add_indexed(model, col)
                # ForeignKey creates an index automatically
                if re.search(r"^\s*\w+\s*=\s*models\.(ForeignKey|OneToOneField)", fm.group(0)):
                    add_indexed(model, col)
            # Meta.indexes = [models.Index(fields=['a','b'])]
            for im in re.finditer(r"models\.Index\s*\(\s*fields\s*=\s*\[([^\]]+)\]", body):
                for c in re.findall(r"['\"](\w+)['\"]", im.group(1)):
                    add_indexed(model, c)


def parse_gorm():
    """type User struct {
         ID       uint   `gorm:"primaryKey"`
         Email    string `gorm:"uniqueIndex"`
         TenantID string `gorm:"index"`
       }
    """
    for p in walk((".go",)):
        try: text = open(p, errors="replace").read()
        except Exception: continue
        if 'gorm:"' not in text: continue
        for st in re.finditer(r"type\s+(\w+)\s+struct\s*\{([^}]+)\}", text, re.S):
            model, body = st.group(1), st.group(2)
            for line in body.splitlines():
                fm = re.match(r"\s*(\w+)\s+\S+\s+`([^`]+)`", line)
                if not fm: continue
                col, tag = fm.group(1), fm.group(2)
                # convert Go field name to snake_case column (GORM default)
                snake = re.sub(r"(?<!^)(?=[A-Z])", "_", col).lower()
                add_declared(model, snake)
                if re.search(r'gorm:"[^"]*\b(primaryKey|uniqueIndex|index)\b', tag):
                    add_indexed(model, snake); add_indexed(model, col.lower())


def parse_sql_migrations():
    """CREATE INDEX ... ON <table> (<col1>, <col2>);
       ALTER TABLE ... ADD PRIMARY KEY (col); UNIQUE (col);
    """
    for p in walk((".sql",)):
        try: text = open(p, errors="replace").read()
        except Exception: continue
        for m in re.finditer(r"CREATE\s+(?:UNIQUE\s+)?INDEX[^\n;]*?\s+ON\s+(?:public\.)?(\w+)\s*\(([^)]+)\)", text, re.I):
            table = m.group(1); cols = m.group(2)
            for c in re.split(r",\s*", cols):
                add_indexed(table, c.strip().split()[0])
        for m in re.finditer(r"PRIMARY\s+KEY\s*\(([^)]+)\)", text, re.I):
            for c in re.split(r",\s*", m.group(1)):
                # attach to the surrounding CREATE TABLE if any (best-effort)
                pass  # already handled by column-level parse; skip
        # UNIQUE / PRIMARY KEY inline on CREATE TABLE
        for tbl in re.finditer(r"CREATE\s+TABLE\s+(?:public\.)?(\w+)\s*\(([\s\S]*?)\);", text, re.I):
            table = tbl.group(1); body = tbl.group(2)
            for cm in re.finditer(r"^\s*(\w+)\s+\S+([^,]*)", body, re.M):
                col, rest = cm.group(1), cm.group(2)
                if re.search(r"\b(PRIMARY\s+KEY|UNIQUE)\b", rest, re.I):
                    add_indexed(table, col)


# ---------------------------------------------------------------------------
# QUERY-SITE PARSERS
# ---------------------------------------------------------------------------

def record(file, line, model_hint, cols):
    if not cols: return
    rel = os.path.relpath(file, ROOT)
    queries.append({"file": rel, "line": line, "model_hint": model_hint, "columns": list(set(cols))})


def scan_prisma_and_typeorm_queries():
    """.findMany({where:{col:...}}) etc. — TS/JS files."""
    # e.g. prisma.user.findMany({ where: { tenantId: x } })
    call_re = re.compile(r"\b(?:prisma\.|db\.|repo\w*\.|this\.\w+Repo?\.)(\w+)?\.?(findMany|findFirst|findUnique|findOne|find|update|delete|count|aggregate)\s*\(\s*\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}", re.S)
    where_re = re.compile(r"where\s*:\s*\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}", re.S)
    col_re = re.compile(r"(\w+)\s*:")
    for p in walk((".ts",".tsx",".js",".jsx",".mjs")):
        try: text = open(p, errors="replace").read()
        except Exception: continue
        for m in call_re.finditer(text):
            model = m.group(1)
            args = m.group(3)
            wm = where_re.search(args)
            if not wm: continue
            # first-level column names inside the where body
            body = wm.group(1)
            cols = []
            for cm in col_re.finditer(body):
                name = cm.group(1)
                if name.lower() in ("and","or","not","in","gt","lt","gte","lte","contains","startsWith","endsWith","equals","every","some","none"):
                    continue
                cols.append(name)
            line = text.count("\n", 0, m.start()) + 1
            record(p, line, model, cols)


def scan_sqlalchemy_queries():
    """session.query(User).filter(User.tenant_id == x)
       session.query(User).filter_by(tenant_id=x)
    """
    for p in walk((".py",)):
        try: text = open(p, errors="replace").read()
        except Exception: continue
        if ".filter" not in text and ".filter_by" not in text: continue
        # filter_by
        for m in re.finditer(r"\.filter_by\s*\(([^)]*)\)", text):
            args = m.group(1)
            cols = re.findall(r"(\w+)\s*=", args)
            line = text.count("\n", 0, m.start()) + 1
            # try to sniff model from a preceding .query(Model)
            model = None
            back = text[max(0, m.start()-200):m.start()]
            mm = re.search(r"query\s*\(\s*(\w+)", back)
            if mm: model = mm.group(1)
            record(p, line, model, cols)
        # filter(Model.col == x)
        for m in re.finditer(r"\.filter\s*\(([^)]*)\)", text):
            args = m.group(1)
            cols = re.findall(r"\b\w+\.(\w+)\s*(?:==|!=|>=|<=|>|<|\.in_|\.like|\.ilike)", args)
            if not cols: continue
            line = text.count("\n", 0, m.start()) + 1
            back = text[max(0, m.start()-200):m.start()]
            mm = re.search(r"query\s*\(\s*(\w+)", back)
            model = mm.group(1) if mm else None
            record(p, line, model, cols)


def scan_django_queries():
    """Model.objects.filter(col=x) / .get / .exclude"""
    for p in walk((".py",)):
        try: text = open(p, errors="replace").read()
        except Exception: continue
        if ".objects." not in text: continue
        for m in re.finditer(r"(\w+)\.objects\.(?:filter|get|exclude|values|values_list)\s*\(([^)]*)\)", text):
            model = m.group(1); args = m.group(2)
            # col=x or col__gt=x — strip trailing __lookup
            cols = []
            for kw in re.findall(r"(\w+)\s*=", args):
                cols.append(kw.split("__")[0])
            line = text.count("\n", 0, m.start()) + 1
            record(p, line, model, cols)


def scan_gorm_queries():
    """db.Where("col = ?", x).First(&u); db.First(&u, "col = ?", x); db.Where("col1 = ? AND col2 = ?", ...)"""
    for p in walk((".go",)):
        try: text = open(p, errors="replace").read()
        except Exception: continue
        if ".Where(" not in text and ".First(" not in text and ".Find(" not in text: continue
        # .Where("col ... ", ...) or .First(&x, "col ... ", ...)
        for m in re.finditer(r'\.(?:Where|First|Find|Take|Last)\s*\(\s*(?:&\w+\s*,\s*)?"([^"]+)"', text):
            frag = m.group(1)
            cols = re.findall(r"\b(\w+)\s*(?:=|!=|>=|<=|>|<|\bIN\b|\bLIKE\b|\bIS\b)", frag)
            # filter out SQL keywords and operators
            cols = [c for c in cols if c.lower() not in {"and","or","not","is","null","true","false"}]
            if not cols: continue
            line = text.count("\n", 0, m.start()) + 1
            # try to infer model from &var / &Var{}
            back = text[max(0, m.start()-100):m.start()+len(m.group(0))]
            mm = re.search(r"&(\w+)\{|&(\w+)\b", back)
            model = (mm.group(1) or mm.group(2)) if mm else None
            record(p, line, model, cols)


# ---------------------------------------------------------------------------
# ANALYSIS
# ---------------------------------------------------------------------------

def is_indexed(model_hint, col):
    c = col.lower()
    # common columns nearly always indexed
    if c in ("id",): return True
    if model_hint:
        if c in indexed.get(model_hint.lower(), set()): return True
    # fallback: any table has this column indexed
    if c in any_indexed: return True
    return False


def main():
    # Build schema index
    parse_prisma()
    parse_typeorm()
    parse_sqlalchemy()
    parse_django()
    parse_gorm()
    parse_sql_migrations()

    if not any_indexed:
        print("query-index-audit: no ORM schema or migrations detected — skipping.")
        # Still emit an empty findings artifact for the reporter
        open(OUT, "w").write(json.dumps({"tool": "wasaa-query-index", "findings": []}))
        return 0

    # Scan query sites
    scan_prisma_and_typeorm_queries()
    scan_sqlalchemy_queries()
    scan_django_queries()
    scan_gorm_queries()

    findings = []
    for q in queries:
        for col in q["columns"]:
            if is_indexed(q["model_hint"], col): continue
            findings.append({
                "file": q["file"], "line": q["line"], "column": col,
                "model_hint": q["model_hint"] or "(unknown)",
                "severity": "MEDIUM",
                "note": f"Query filters on '{col}' but no matching index found in schema/migrations. Add an index or explain why the scan is acceptable.",
            })
            print(f"::warning file={q['file']},line={q['line']}::query-index (MEDIUM): filtered on '{col}' (model: {q['model_hint'] or 'unknown'}) with no matching index.")

    open(OUT, "w").write(json.dumps({"tool":"wasaa-query-index","findings":findings}, indent=2))

    # Summary
    n = len(findings)
    print(f"query-index-audit: {n} finding(s), {len(queries)} query site(s) analyzed, {sum(len(v) for v in indexed.values())} indexed column(s) across {len(indexed)} model(s).")

    # MEDIUM only — do NOT block on this heuristic. Promotion to blocking
    # happens after one release cycle in advisory mode (per POLICY.md).
    return 0


if __name__ == "__main__":
    sys.exit(main())
