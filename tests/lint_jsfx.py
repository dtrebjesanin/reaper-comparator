import re, sys, pathlib
src = pathlib.Path(__file__).resolve().parent.parent / 'Comparator_Tap.jsfx'
text = src.read_text()
checks = [
    (r'^desc:Comparator Tap\s*$', 'desc line must be exactly "Comparator Tap"'),
    (r'^options:gmem=Comparator\s*$', 'gmem namespace must be Comparator'),
    (r'^slider1:tap_id=-1<-1,511,1>-', 'hidden tap_id slider, default -1, range -1..511'),
    (r'@init\b', '@init section'), (r'@slider\b', '@slider section'),
    (r'@sample\b', '@sample section'), (r'@block\b', '@block section'),
    (r'fft_real\(', 'must use fft_real'), (r'fft_permute\(', 'must call fft_permute'),
    (r'BASE = 256', 'slot base 256 (protocol v2)'), (r'STRIDE = 256', 'stride 256 (protocol v2)'),
    (r'gmem\[0\] = 2', 'protocol version write (v2)'),
    (r'gmem\[base \+ 3\] = 2', 'per-tap protocol version at +3 (v2)'),
    (r'gmem\[base \+ 8 \+ b\]', 'pL (smL) written at offset +8'),
    (r'gmem\[base \+ 40 \+ b\]', 'pR (smR) written at offset +40'),
    (r'gmem\[base \+ 72 \+ b\]', 'cLR (smX) written at offset +72'),
    (r'gmem\[base \+ 104 \+ b\]', 'pk written at offset +104'),
]
fails = [msg for pat, msg in checks if not re.search(pat, text, re.M)]

# protocol v2: both channels get their own FFT every hop (no whichch alternation)
n_fft_real = len(re.findall(r'fft_real\(', text))
if n_fft_real != 2:
    fails.append(f'must call fft_real exactly twice per hop (one per channel buffer), found {n_fft_real}')
n_fft_permute = len(re.findall(r'fft_permute\(', text))
if n_fft_permute != 2:
    fails.append(f'must call fft_permute exactly twice per hop (one per channel buffer), found {n_fft_permute}')
if re.search(r'\bwhichch\b', text):
    fails.append('whichch alternation must be removed - both channels are analyzed every hop in v2')

# balanced parens sanity (EEL2 has no compiler we can run headlessly)
for ch, op, cl in [('parens', '(', ')'), ('brackets', '[', ']')]:
    if text.count(op) != text.count(cl):
        fails.append(f'unbalanced {ch}: {text.count(op)} vs {text.count(cl)}')
if fails:
    print('LINT FAIL:'); [print(' -', f) for f in fails]; sys.exit(1)
print('JSFX LINT PASSED')
