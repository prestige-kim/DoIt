#!/usr/bin/env python3
"""공개 고지 원문과 이미지 출처를 외부 요청 없는 정적 HTML로 복사한다."""
from html import escape
from pathlib import Path

root = Path(__file__).resolve().parent.parent
sections = []
for source, anchor, title in (
    ('LICENSE', 'license', 'MIT 라이선스'),
    ('THIRD_PARTY_NOTICES.md', 'notices', '외부 코드 고지'),
    ('site/assets/credits.txt', 'images', '이미지 출처'),
):
    # Browser text remains identical; entities avoid ambiguous address auto-linking.
    content = escape((root / source).read_text()).replace('@', '&#64;')
    sections.append(f'<section id="{anchor}"><h2>{title}</h2><pre>{content}</pre></section>')
page = '''<!doctype html>
<html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark"><meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'none'; style-src 'self'; img-src 'self'; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"><title>라이선스와 외부 코드 고지 — DoIt</title><link rel="stylesheet" href="./styles.css"><link rel="icon" href="./assets/mark.svg"></head><body><main class="legal content-width"><a class="legal-back" href="./index.html">← DoIt 소개로 돌아가기</a><h1>라이선스와 고지</h1><p>아래 내용은 저장소의 라이선스와 외부 코드 고지 원문입니다.</p>''' + ''.join(sections) + '</main></body></html>\n'
(root / 'site/legal.html').write_text(page)
print('공개 고지 2개와 이미지 출처 동기화 완료')
