#!/usr/bin/env python3
"""Post a flashable ASB zip to the owner's Telegram forum.

Test builds go to the "Test" topic, releases to the "Last Release" topic; each kind needs its
own topic id, so a build can never land in the wrong place. Without the token, chat id or the
topic id for this kind the script says so and does nothing. A Telegram error never fails a build.

usage: telegram_post.py test|release <zip> <version>
env:   TG_TOKEN, TG_CHAT, TG_TOPIC
text:  docs/TELEGRAM_POST.txt (test) or docs/TELEGRAM_RELEASE.txt (release); one item per line,
       lines starting with # are skipped.
"""
import html
import json
import os
import subprocess
import sys


def items(path):
    out = []
    try:
        with open(path, encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    out.append(html.escape(line))
    except OSError:
        pass
    return out


def caption(kind, ver):
    if kind == 'release':
        lines = items('docs/TELEGRAM_RELEASE.txt') or ['Стабильная версия со всеми исправлениями тестовых сборок.']
        cap = '🚀 <b>AutoSystemBoost ' + html.escape(ver) + '</b>\n'
        cap += 'Новый релиз!\n\n'
        cap += '\n'.join('✅ ' + x for x in lines[:14])
        cap += '\n\n📲 Прошить через KernelSU, Magisk или APatch и перезагрузиться.'
        cap += '\n🔄 Настройки сохраняются при обновлении.'
    else:
        lines = items('docs/TELEGRAM_POST.txt') or ['Подправил оптимизацию.', 'Подправил WebUI.']
        cap = '🛸 <b>AutoSystemBoost ' + html.escape(ver) + '</b>\n'
        cap += 'Новая тестовая сборка!\n\n'
        cap += '\n'.join('✅ ' + x for x in lines[:12])
        cap += '\n\n📲 Прошить через KernelSU, Magisk или APatch и перезагрузиться.'
        cap += '\n🧪 Это тестовая сборка: при проблемах пришлите asbdiag и лог.'
    return cap[:1024]


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ('test', 'release'):
        print(__doc__)
        return 0
    kind, zip_path, ver = sys.argv[1:]
    token, chat, topic = (os.environ.get(k, '').strip() for k in ('TG_TOKEN', 'TG_CHAT', 'TG_TOPIC'))
    if not token or not chat:
        print('::notice::Telegram token or chat id is not set - nothing posted')
        return 0
    if not topic.lstrip('-').isdigit():
        print('::notice::Telegram topic id for %s builds is not set - nothing posted' % kind)
        return 0
    if not os.path.isfile(zip_path):
        print('::warning::%s not found - nothing posted' % zip_path)
        return 0
    cap = caption(kind, ver)
    print(cap)
    cmd = ['curl', '-sS', '-o', 'tg_out.json', '-w', '%{http_code}',
           '--form-string', 'chat_id=' + chat,
           '--form-string', 'message_thread_id=' + topic,
           '--form-string', 'caption=' + cap,
           '--form-string', 'parse_mode=HTML',
           '-F', 'document=@' + zip_path,
           'https://api.telegram.org/bot%s/sendDocument' % token]
    try:
        code = subprocess.run(cmd, capture_output=True, text=True, timeout=180).stdout.strip()
    except Exception as e:
        print('::warning::Telegram request failed: %s' % type(e).__name__)
        return 0
    desc = ''
    try:
        with open('tg_out.json', encoding='utf-8') as f:
            desc = json.load(f).get('description', '')
        os.remove('tg_out.json')
    except Exception:
        pass
    if code == '200':
        print('Posted %s to Telegram (%s topic)' % (zip_path, kind))
    else:
        print('::warning::Telegram answered HTTP %s: %s' % (code, desc[:200]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
