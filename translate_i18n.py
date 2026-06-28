import urllib.request
import json
import re
import urllib.parse
import time

def translate_text(text):
    if not text.strip(): return text
    url = 'https://translate.googleapis.com/translate_a/single?client=gtx&sl=zh-CN&tl=tr&dt=t&q=' + urllib.parse.quote(text)
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        response = urllib.request.urlopen(req)
        data = json.loads(response.read().decode('utf-8'))
        return ''.join(item[0] for item in data[0])
    except Exception as e:
        print('Error translating:', text, e)
        return text

with open('frontend/src/utils/i18n.ts', 'r', encoding='utf-8') as f:
    content = f.read()

# find exact dictionary
exact_match = re.search(r'const exact: Record<string, string> = \{(.*?)\}', content, re.DOTALL)
if exact_match:
    exact_content = exact_match.group(1)
    lines = exact_content.split('\n')
    new_lines = []
    for line in lines:
        if ':' in line:
            parts = line.split(':', 1)
            key = parts[0].strip()
            # remove quotes
            raw_key = key[1:-1] if (key.startswith("'") and key.endswith("'")) else key
            if raw_key:
                tr_text = translate_text(raw_key)
                # escape single quotes
                tr_text = tr_text.replace("'", "\\'")
                new_line = f"  '{raw_key}': '{tr_text}',"
                new_lines.append(new_line)
                print(f'{raw_key} -> {tr_text}')
                time.sleep(0.1)
            else:
                new_lines.append(line)
        else:
            new_lines.append(line)
    
    new_exact = 'const exact: Record<string, string> = {\n' + '\n'.join(new_lines) + '\n}'
    content = content.replace(exact_match.group(0), new_exact)

with open('frontend/src/utils/i18n.ts', 'w', encoding='utf-8') as f:
    f.write(content)

print('Translation completed!')
