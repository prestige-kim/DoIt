#!/usr/bin/python3
"""번들 업데이트 설정 준비·배포 포장 검사. 키 내용·주소는 진단에 출력하지 않는다."""
import base64
import copy
import plistlib
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

def configured(info):
    key = info.get('SUPublicEDKey', '')
    try:
        raw = base64.b64decode(key, validate=True)
        if len(raw) != 32 or not any(raw) or base64.b64encode(raw).decode() != key:
            return False
    except (ValueError, TypeError):
        return False
    text = info.get('SUFeedURL', '')
    if not isinstance(text, str) or not text or any(c.isspace() for c in text) or '$(' in text:
        return False
    try:
        u = urlsplit(text)
        if u.username is not None or u.password is not None or u.query or u.fragment or not u.path.endswith('.xml'):
            return False
        if type(info.get('DoItUpdateValidation')) is not bool:
            return False
        if info['DoItUpdateValidation']:
            return u.scheme == 'http' and u.hostname == '127.0.0.1' and u.port == 8765
        h = u.hostname or ''
        return (u.scheme == 'https' and '.' in h and not re.fullmatch(r'[0-9.]+', h)
                and not h.endswith(('.invalid', '.localhost', '.local')) and ':' not in h and u.port in (None, 443))
    except ValueError:
        return False

def ready(info):
    return configured(info) and (info.get('DoItUpdateValidation') is True
                                 or info.get('DoItDistributionEnabled') is True)

def check_package(info):
    ats = info.get('NSAppTransportSecurity', {})
    return (info.get('DoItUpdateValidation') is False and not ats and ready(info)
            and info.get('SUVerifyUpdateBeforeExtraction') is True
            and info.get('SUAllowsAutomaticUpdates') is False
            and info.get('SUAutomaticallyUpdate') is False
            and info.get('SUEnableSystemProfiling') is False)

def main():
    action, filename = sys.argv[1:3]
    with open(filename, 'rb') as f:
        info = plistlib.load(f)
    if action == 'prepare':
        destination, config = sys.argv[3:5]
        info = copy.deepcopy(info)
        info['DoItUpdateValidation'] = config == 'UpdateValidation'
        if config == 'UpdateValidation':
            info['SUFeedURL'] = 'http://127.0.0.1:8765/appcast.xml'
            info['NSAppTransportSecurity'] = {'NSAllowsLocalNetworking': True}
        if not configured(info):
            print('note: DoIt update address/key/configuration is invalid; updater and distribution packaging are disabled.')
        elif not ready(info):
            print('note: DoIt distribution is not enabled; updater and distribution packaging remain disabled.')
        Path(destination).parent.mkdir(parents=True, exist_ok=True)
        with open(destination, 'wb') as f:
            plistlib.dump(info, f, sort_keys=True)
    elif action == 'package':
        if not check_package(info):
            print('배포 포장 차단: 공개 준비 완료·실 HTTPS 주소·공개 키·정식 구성·보안 설정을 확인하세요.')
            return 1
    else:
        return 1
    return 0

if __name__ == '__main__':
    sys.exit(main())
