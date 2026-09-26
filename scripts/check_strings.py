#!/usr/bin/env python3
"""Lists user-facing strings in Sources/ that have no entry in Resources/hr.lproj/Localizable.strings."""
import re, glob, os, sys
os.chdir(os.path.join(os.path.dirname(__file__), '..'))
hr = dict(re.findall(r'^"((?:[^"\\]|\\.)*)" = "((?:[^"\\]|\\.)*)";', open('Resources/hr.lproj/Localizable.strings').read(), re.M))
call = re.compile(r'(?:\b(?:Text|Button|Label|Toggle|Picker|Section|TableColumn|TextField|SecureField|Stepper|DatePicker|DisclosureGroup|LabeledContent|help|L|confirmationDialog|alert|navigationTitle)\(|(?:title|text|prompt):\s*)"((?:[^"\\]|\\.)*)"')
INT = r'(count|retentionDays|maxDelete|uploaded|archived|modtimeFixed|activeCount|files|totalFiles)\)?$'
def key(k):
    return re.sub(r'\\\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)',
                  lambda m: '%lld' if re.search(INT, m.group(0)[2:-1].strip()) else '%@', k)
missing = []
for f in sorted(glob.glob('Sources/**/*.swift', recursive=True)):
    if f.endswith('SelfTest.swift'): continue
    for m in call.finditer(open(f).read()):
        k = key(m.group(1))
        if k and k not in hr and not re.fullmatch(r'[\W\d_]*', k) and k not in missing:
            missing.append(k)
for k in missing: print(k)
sys.exit(1 if missing else 0)
