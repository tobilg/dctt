#!/usr/bin/env python3
"""Explicit synthetic development fixtures, never microphone recordings."""
import subprocess
import wave
from pathlib import Path

root = Path(__file__).resolve().parents[1] / '.build/fixtures'
root.mkdir(parents=True, exist_ok=True)
sentences = {
    'short': 'Please review the updated draft. I do not want to delete the backup. The meeting starts at nine thirty tomorrow.',
    'long': 'Please review the updated draft. I do not want to delete the backup. The meeting starts at nine thirty tomorrow. The project is called Cedar. We need twelve boxes, three cables, and two monitors. Keep the original file and save a separate copy. Send the notes after the meeting. This is a local dictation test.',
}
for name, seconds in [('short', 10), ('long', 30)]:
    text = sentences[name]
    path = root / (name + '.wav')
    # Keep synthesized speech shorter than the target and pad with digital silence.
    subprocess.run(['say', '-v', 'Samantha', '-r', '165', '--data-format=LEI16@16000', '--file-format=WAVE', '-o', str(path), text], check=True)
    with wave.open(str(path), 'rb') as f:
        data, params = f.readframes(f.getnframes()), f.getparams()
    target = seconds * 16000 * 2
    if len(data) > target:
        raise RuntimeError(f'{name} is too long; increase the synthesis rate, do not truncate words')
    with wave.open(str(path), 'wb') as f:
        f.setparams(params)
        f.writeframes(data + bytes(target - len(data)))
    (root / (name + '.txt')).write_text(text + '\n')
with wave.open(str(root / 'long.wav'), 'rb') as f:
    data, params = f.readframes(f.getnframes()), f.getparams()
with wave.open(str(root / 'maximum.wav'), 'wb') as f:
    f.setparams(params)
    f.writeframes(data * 4)
(root / 'maximum.txt').write_text((sentences['long'] + ' ') * 4 + '\n')
print(root)
