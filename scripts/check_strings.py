#!/usr/bin/env python3
"""Lists user-facing strings in Sources/ that have no entry in the hr and de Localizable.strings."""
import re, glob, os, sys
os.chdir(os.path.join(os.path.dirname(__file__), '..'))
def table(lang):
    return dict(re.findall(r'^"((?:[^"\\]|\\.)*)" = "((?:[^"\\]|\\.)*)";', open(f'Resources/{lang}.lproj/Localizable.strings').read(), re.M))
tables = {lang: table(lang) for lang in ('hr', 'de')}
call = re.compile(r'(?:\b(?:Text|Button|Label|Toggle|Picker|Section|TableColumn|TextField|SecureField|Stepper|DatePicker|DisclosureGroup|LabeledContent|ContentUnavailableView|SectionTitle|help|L|confirmationDialog|alert|navigationTitle)\(|(?:title|text|prompt):\s*)"((?:[^"\\]|\\.)*)"')
INT = r'(count|retentionDays|maxDelete|uploaded|archived|modtimeFixed|activeCount|files|totalFiles)\)?$'
def key(k):
    return re.sub(r'\\\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)',
                  lambda m: '%lld' if re.search(INT, m.group(0)[2:-1].strip()) else '%@', k)
missing = []
for f in sorted(glob.glob('Sources/**/*.swift', recursive=True)):
    if f.endswith('SelfTest.swift'): continue
    for m in call.finditer(open(f).read()):
        k = key(m.group(1))
        for lang, t in tables.items():
            if k and k not in t and not re.fullmatch(r'[\W\d_]*', k) and (lang, k) not in missing:
                missing.append((lang, k))
for lang, k in missing: print(f'{lang}: {k}')
sys.exit(1 if missing else 0)
