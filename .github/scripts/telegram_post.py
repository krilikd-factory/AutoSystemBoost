#!/usr/bin/env python3
"""Post a flashable ASB zip to the owner's Telegram forum.

Test builds go to the "Test" topic, releases to the "Last Release" topic; each kind needs its
own topic id, so a build can never land in the wrong place. Without the token, chat id or the
topic id for this kind the script says so and does nothing. A Telegram error never fails a build.

usage: telegram_post.py test|release <zip> <version>
env:   TG_TOKEN, TG_CHAT, TG_TOPIC (topic id) or TG_ANCHOR (any message already in that
       topic: a silent reply to it reveals the topic id and is deleted at once), RUN_URL
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


def caption(kind, ver, run_url=''):
    if kind == 'release':
        lines = items('docs/TELEGRAM_RELEASE.txt') or ['Стабильная версия со всеми исправлениями тестовых сборок.']
        cap = '🚀 <b>AutoSystemBoost ' + html.escape(ver) + '</b>\n'
        cap += 'Новый релиз!\n\n'
        cap += '\n'.join('✅ ' + x for x in lines[:14])
        cap += '\n\n🔄 Настройки сохраняются при обновлении.'
    else:
        lines = items('docs/TELEGRAM_POST.txt') or ['Подправил оптимизацию.', 'Подправил WebUI.']
        cap = '🛸 <b>AutoSystemBoost ' + html.escape(ver) + '</b>\n'
        cap += 'Новая тестовая сборка!\n\n'
        cap += '\n'.join('✅ ' + x for x in lines[:12])
        cap += '\n\n🧪 Это тестовая сборка. При проблемах пришлите asbdiag и Вечный лог.'
    if run_url:
        cap += '\n⚙️ <a href="' + html.escape(run_url, quote=True) + '">' + ('Релиз на GitHub' if kind == 'release' else 'Сборка на GitHub') + '</a>'
    return cap[:1024]


def main():
    if len(sys.argv) == 3 and sys.argv[1] == 'probe':
        token, chat = os.environ.get('TG_TOKEN', '').strip(), os.environ.get('TG_CHAT', '').strip()
        if token and chat and sys.argv[2].isdigit():
            topic_of(token, chat, sys.argv[2])
        return 0
    if len(sys.argv) != 4 or sys.argv[1] not in ('test', 'release'):
        print(__doc__)
        return 0
    kind, zip_path, ver = sys.argv[1:]
    token, chat, topic, anchor, run_url = (os.environ.get(k, '').strip() for k in
                                           ('TG_TOKEN', 'TG_CHAT', 'TG_TOPIC', 'TG_ANCHOR', 'RUN_URL'))
    if not token or not chat:
        print('::notice::Telegram token or chat id is not set - nothing posted')
        return 0
    if not topic.isdigit() and anchor.isdigit():
        topic = topic_of(token, chat, anchor)
    if not topic.isdigit():
        print('::notice::Telegram topic for %s builds is not known - nothing posted' % kind)
        return 0
    if not os.path.isfile(zip_path):
        print('::warning::%s not found - nothing posted' % zip_path)
        return 0
    cap = caption(kind, ver, run_url)
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
    desc, posted_id = '', ''
    try:
        with open('tg_out.json', encoding='utf-8') as f:
            body = json.load(f)
        desc = body.get('description', '')
        posted_id = str((body.get('result') or {}).get('message_id', ''))
        os.remove('tg_out.json')
    except Exception:
        pass
    if code == '200':
        print('Posted %s to Telegram (%s topic)' % (zip_path, kind))
        if os.environ.get('TG_PIN', '').strip().lower() in ('1', 'true', 'yes') and posted_id.isdigit():
            r = api(token, 'pinChatMessage', {'chat_id': chat, 'message_id': posted_id,
                                              'disable_notification': 'false'})
            if r.get('ok'):
                print('Pinned the post (members notified)')
            else:
                print('::warning::could not pin the post: %s' % str(r.get('description', ''))[:160])
    else:
        print('::warning::Telegram answered HTTP %s: %s' % (code, desc[:200]))
        explain_chat(token, chat, topic)
    return 0


def api(token, method, fields):
    cmd = ['curl', '-sS']
    for k, v in fields.items():
        cmd += ['--form-string', '%s=%s' % (k, v)]
    cmd.append('https://api.telegram.org/bot%s/%s' % (token, method))
    try:
        return json.loads(subprocess.run(cmd, capture_output=True, text=True, timeout=60).stdout or '{}')
    except Exception:
        return {}


def topic_of(token, chat, anchor):
    """Topic id of the forum topic holding message <anchor>.

    The Bot API cannot look a message up, but a reply lands in the replied message's topic
    and Telegram returns that topic id. The probe is silent and deleted straight away."""
    r = api(token, 'sendMessage', {'chat_id': chat, 'text': '·', 'disable_notification': 'true',
                                   'reply_parameters': json.dumps({'message_id': int(anchor)})})
    msg = r.get('result') or {}
    if not msg:
        print('::warning::topic lookup by message %s failed: %s' % (anchor, str(r.get('description', ''))[:160]))
        return ''
    api(token, 'deleteMessage', {'chat_id': chat, 'message_id': str(msg.get('message_id', ''))})
    tid = msg.get('message_thread_id')
    if not tid or not msg.get('is_topic_message'):
        print('::warning::message %s is not inside a topic - nothing posted' % anchor)
        return ''
    print('::notice::message %s is in topic %s' % (anchor, tid))
    return str(tid)


def explain_chat(token, chat, topic):
    """On a failed post, say which chat the bot reached and whether it has topics."""
    try:
        out = subprocess.run(['curl', '-sS', '--form-string', 'chat_id=' + chat,
                              'https://api.telegram.org/bot%s/getChat' % token],
                             capture_output=True, text=True, timeout=30).stdout
        r = json.loads(out).get('result') or {}
        if not r:
            print('::warning::the bot cannot see the chat set as TELEGRAM_CHAT_ID (wrong id, or the bot is not a member)')
            return
        print('::notice::chat seen by the bot: type=%s title=%s username=%s forum=%s; topic asked: %s' % (
            r.get('type'), r.get('title'), r.get('username') or '-', r.get('is_forum', False), topic))
    except Exception as e:
        print('::warning::getChat failed: %s' % type(e).__name__)


if __name__ == '__main__':
    sys.exit(main())
