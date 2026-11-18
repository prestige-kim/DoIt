# 외부 코드·자산 고지

Sparkle 2.10.1을 공식 SPM 바이너리 패키지로 포함합니다. 아래에 배포본의 라이선스·외부 고지 전체를 보존합니다. 나머지 참고 프로젝트는 현재 소스 주석과 이전 구현 기록을 대조했으며 과거의 모든 작성 과정을 독립적으로 확인한 것은 아닙니다.

- NotchDrop·NotchNotification (Lakr233): 구조 참고 대상으로 검토했습니다. 초기 구현 기록은 NotchDrop 코드를 사용하지 않았다고 명시하며, 현재 소스에도 차용을 나타내는 주석은 없습니다. NotchNotification의 실제 차용 여부는 기록만으로 확정하지 못했습니다. 차용이 확인되면 원 프로젝트의 공식 저작권·라이선스 전문을 보존해야 합니다.
- 2026-11-10 공식 원문 대조: [NotchDrop LICENSE](https://github.com/Lakr233/NotchDrop/blob/e70b3d715a99e47de6eb823540282eafc7401a3a/LICENSE) · [NotchNotification LICENSE](https://github.com/Lakr233/NotchNotification/blob/961007f624ff73963c51608c9f0774b094419faa/LICENSE). 두 원문은 MIT이며 저작권 표기는 `Copyright (c) 2024 Lakr Aream`입니다. 이는 참고 프로젝트의 라이선스 확인이며 DoIt의 차용 사실을 뜻하지 않습니다. 초기·후속·현재 코드 대조에서도 NotchNotification의 과거 차용 여부는 확정하지 못했습니다.
- Boring Notch (TheBoredTeam): 동작 이해를 위한 참고 대상이며 코드 복사는 금지되어 있습니다. 초기 구현 기록은 코드 사용이 없었다고 명시합니다.
- 앱 아이콘과 메뉴바 아이콘은 저장소의 `scripts/make-icons.swift`로 생성한 도형 자산입니다.
- 웹사이트 이미지의 제작 출처와 별도 권리 사항은 [이미지 출처](site/assets/credits.txt)에 기록합니다. 랜딩 배경과 메뉴바는 자체 제작했습니다.
- Sparkle 2.10.1: [공식 배포본](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1) · [고정 버전 LICENSE](https://github.com/sparkle-project/Sparkle/blob/2.10.1/LICENSE). 원문은 아래와 같습니다.

이 문서는 DoIt 자체의 [MIT 라이선스](LICENSE)를 대체하지 않습니다. 새 외부 코드나 자산을 포함할 때 출처와 원 저작권 고지를 함께 갱신합니다.

## NotchNotification — 예방적 MIT 고지

실제 차용 여부는 확인되지 않았으며, 참고 프로젝트의 저작권 고지를 예방적으로 보존합니다.

[공식 LICENSE 고정 원문](https://github.com/Lakr233/NotchNotification/blob/961007f624ff73963c51608c9f0774b094419faa/LICENSE)

```text
MIT License

Copyright (c) 2024 Lakr Aream

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Sparkle 2.10.1 — LICENSE 및 EXTERNAL LICENSES

```text
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=================
EXTERNAL LICENSES
=================

bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

Copyright 2003-2005 Colin Percival
All rights reserved

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

--

sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

The sais-lite copyright is as follows:

Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

--

Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

This software is provided 'as-is', without any express or implied warranty. In no event will the
authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial
applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the
   original software. If you use this software in a product, an acknowledgment in the product
   documentation would be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and must not be misrepresented as
   being the original software.

3. This notice may not be removed or altered from any source distribution.

--

SUSignatureVerifier.m:

Copyright (c) 2011 Mark Hamlin.

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

## Windows판 — 설치본에 함께 들어가는 Microsoft 구성요소

Windows판(`windows/`)은 .NET 자체 포함(self-contained) 게시로 만들며, 설치 파일에 아래 구성요소의 실행 파일이 함께 들어갑니다. 버전은 `windows/DoIt.Windows/DoIt.Windows.csproj`와 .NET SDK 10.0.404(번들 런타임 10.0.15) 기준입니다. 라이선스 이름과 원문은 각 NuGet 패키지에 들어 있는 파일과 nuspec의 license 항목으로 확인했습니다. 설치 폴더의 `Licenses/`에는 DoIt 라이선스와, 빌드에 쓰인 패키지 안의 라이선스·고지 파일 원문이 복사됩니다.

| 구성요소 | 버전 | 라이선스 | 확인 근거 |
|---|---|---|---|
| .NET 런타임 (Microsoft.NETCore.App, 실행 호스트 포함) | 10.0.15 | MIT | `microsoft.netcore.app.host.win-x64` 10.0.15 패키지의 `LICENSE.TXT`·`THIRD-PARTY-NOTICES.TXT`, nuspec `license=MIT` |
| WPF 등 Windows 데스크톱 런타임 (Microsoft.WindowsDesktop.App) | 10.0.15 | MIT | 같은 버전 `microsoft.windowsdesktop.app.ref` 패키지의 `LICENSE`, nuspec `license=MIT` |
| Windows App SDK Foundation | 2.6.5 | Microsoft Software License Terms (Windows App SDK) | 패키지의 `license.txt`, nuspec `license type=file` |
| Windows App SDK Runtime | 2.6.5 | 위와 같음, 제3자 고지 `NOTICE.txt` 포함 | 패키지의 `license.txt`·`NOTICE.txt` |
| Windows App SDK Base · InteractiveExperiences (Foundation·Runtime의 의존 패키지) | 2.6.5 | 위와 같음 (Base에는 같은 `NOTICE.txt` 포함) | 각 패키지의 `license.txt`, Base의 `NOTICE.txt` |
| Windows SDK .NET 투영 (Microsoft.Windows.SDK.NET.Ref: `Microsoft.Windows.SDK.NET.dll`, `WinRT.Runtime.dll`) | 10.0.19041.57 | 패키지 안에 라이선스 파일이 없고, nuspec은 Windows SDK 라이선스 주소(https://aka.ms/WinSDKLicenseURL)만 가리킵니다 | nuspec `licenseUrl`. 원문은 아직 확인하지 못했습니다 |

빌드할 때만 쓰고 설치본에는 들어가지 않는 패키지(Microsoft.Windows.SDK.BuildTools, Microsoft.Windows.SDK.BuildTools.MSIX)는 표에서 뺐습니다.

### .NET 런타임·Windows 데스크톱 런타임(WPF) — MIT

아래는 `microsoft.netcore.app.host.win-x64` 10.0.15 패키지의 `LICENSE.TXT` 원문입니다. `microsoft.windowsdesktop.app.ref` 10.0.15의 `LICENSE`도 같은 MIT 문구와 저작권 표기입니다. .NET 런타임이 쓰는 제3자 구성요소 고지(`THIRD-PARTY-NOTICES.TXT`)는 길어서 여기에 옮기지 않았으며, 공식 저장소(https://github.com/dotnet/runtime/blob/main/THIRD-PARTY-NOTICES.TXT)에서 볼 수 있습니다.

```text
The MIT License (MIT)

Copyright (c) .NET Foundation and Contributors

All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Windows App SDK 2.6.5 — Microsoft Software License Terms

Windows App SDK는 오픈소스 라이선스가 아니라 Microsoft 소프트웨어 사용 조건(MICROSOFT SOFTWARE LICENSE TERMS — MICROSOFT WINDOWS APP SDK)을 따릅니다. 원문은 4개 패키지(Foundation·Runtime·Base·InteractiveExperiences)의 `license.txt`에 같은 내용으로 들어 있으며 설치본 `Licenses/` 폴더에 그대로 복사됩니다. 핵심 내용은 다음과 같습니다(요약이며 원문이 우선합니다).

- NuGet 패키지가 앱과 함께 배치하는 파일은 자체 포함 배포에서도 재배포할 수 있습니다(3.a.i).
- 재배포할 때는 앱이 주요 기능을 더해야 하고, 배포자와 최종 사용자가 이 계약만큼 Microsoft를 보호하는 조건에 동의하도록 해야 하며, 관련 청구에 대해 Microsoft를 면책해야 합니다(3.b).
- Microsoft 상표를 앱이 Microsoft 제품이거나 보증받은 것처럼 쓰면 안 됩니다(3.c).
- 소프트웨어 안의 Microsoft 및 공급자 고지를 지우거나 바꾸면 안 됩니다(4.c).
- 소프트웨어는 "있는 그대로" 제공되며 Microsoft는 보증하지 않습니다(12).

Runtime·Base 패키지의 `NOTICE.txt`(NOTICES AND INFORMATION)는 Windows App SDK에 포함된 제3자 오픈소스 구성요소 약 80개(Newtonsoft.Json, zlib, protobuf, ONNX 관련 구성요소 등)의 저작권·라이선스 고지입니다. 약 6,200줄이라 여기에 옮기지 않았고 설치본 `Licenses/` 폴더에 원문이 들어갑니다. 이 고지에 따르면 Microsoft는 해당 오픈소스 코드를 https://3rdpartysource.microsoft.com 에서 제공합니다.
