# HEVC Video Extensions 설치 도우미

[![release](https://img.shields.io/github/v/release/SEUNGJU-PARK-KR/hevc-video-extensions)](https://github.com/SEUNGJU-PARK-KR/hevc-video-extensions/releases/latest)
[![ci](https://github.com/SEUNGJU-PARK-KR/hevc-video-extensions/actions/workflows/ci.yml/badge.svg)](https://github.com/SEUNGJU-PARK-KR/hevc-video-extensions/actions/workflows/ci.yml)

Windows 10 / 11 어느 PC에서든 **무료 HEVC 비디오 확장**(Microsoft.HEVCVideoExtension)을 그 PC에 맞는 패키지 버전으로 설치해 주는 스크립트입니다. 설치 파일은 [최신 릴리즈](https://github.com/SEUNGJU-PARK-KR/hevc-video-extensions/releases/latest)에서 받으세요.

```
powershell -ExecutionPolicy Bypass -File .\Install-HEVC.ps1
```

또는 `Install-HEVC.cmd` 더블클릭.

---

## 왜 필요한가

Windows의 HEVC(H.265) 재생은 Store 패키지 `Microsoft.HEVCVideoExtension`(Store ID `9N4WGH0Z6VHQ`)가 담당합니다. 그런데 실제로 설치해 보면 두 가지 벽에 부딪힙니다.

**1. 무료 버전이 Store 검색에 안 뜬다**
유료판(`9NMZLZ57R3T7`, 1,200원)만 검색되고, 무료판은 "설치 참조업체용"이라는 이름으로 숨어 있습니다. `winget install 9N4WGH0Z6VHQ`도 `일치하는 패키지를 찾을 수 없습니다`로 실패합니다.

**2. 최신 패키지가 구형 OS에서 거부된다**
Microsoft는 여러 빌드를 배포하는데, 최신 `2.5.48.0`은 **Windows 11 25H2(빌드 26200) 이상**을 요구합니다. 23H2(22631)에서 그대로 설치하면:

```
0x80073CFD  이 패키지는 Windows.Universal 디바이스 제품군과 호환되지 않습니다.
            ... 10.0.26200.0 이상의 OS 버전이 필요합니다.
```

그래서 이 스크립트는 파일 이름을 하드코딩하지 않고, **각 후보 번들의 매니페스트에서 요구 빌드를 직접 읽어** 현재 PC가 실행할 수 있는 가장 최신 빌드를 고릅니다.

| PC 상태 | 스크립트가 고르는 것 |
|---|---|
| Windows 11 25H2 (26200+) | 최신 빌드 (예: 2.5.48.0) |
| Windows 11 21H2~24H2 (22000~26199) | 그 이하 빌드 (예: 2.4.149.0) |
| Windows 10 1709~22H2 (16299~19045) | 위와 동일 계열의 호환 빌드 |
| ARM64 PC | 번들 내 arm64 페이로드 |
| x86(32비트) OS | 번들 내 x86 페이로드 |
| 이미 설치됨 | 아무것도 하지 않음 (exit 10) |

---

## 사용법

### 그냥 설치

```powershell
.\Install-HEVC.ps1
```

관리자 권한은 필요 없습니다(현재 사용자에 설치). 콘솔에 이 PC 정보 → 후보 검사 → 설치 → 검증 순서로 출력됩니다.

### 이 PC 상태만 확인 (변경 없음)

```powershell
.\Install-HEVC.ps1 -Diagnose
```

출력 예시:

```
2026-10-21 02:31:10 [STEP ] --- this machine ---
2026-10-21 02:31:10 [INFO ] OS          : Windows 11 23H2 (build 10.0.22631.7584)
2026-10-21 02:31:10 [INFO ] Edition     : Professional
2026-10-21 02:31:10 [INFO ] Architecture: x64
2026-10-21 02:31:10 [INFO ] GPU         : NVIDIA GeForce RTX 4070 (driver 32.0.15.7216)
2026-10-21 02:31:10 [STEP ] --- candidate sources ---
2026-10-21 02:31:10 [INFO ]   store      2.5.48.0   Microsoft.HEVCVideoExtension_2.5.48.0_neutral_~_8wekyb3d8bbwe.appxbundle
2026-10-21 02:31:10 [INFO ]   store      2.4.149.0  Microsoft.HEVCVideoExtension_2.4.149.0_neutral_~_8wekyb3d8bbwe.appxbundle
```

### 그 밖의 옵션

| 옵션 | 설명 |
|---|---|
| `-Force` | 이미 설치되어 있어도 재설치/복구 |
| `-Uninstall` | 제거 |
| `-AllUsers` | 모든 사용자에 설치 (관리자 권한 필요) |
| `-Offline` | 네트워크를 쓰지 않고 로컬/캐시 번들만 사용 |
| `-BundlePath <경로>` | 특정 `.appxbundle` 지정 설치 |
| `-CacheDir <경로>` | 다운로드 캐시 위치 변경 |
| `-LogFile <경로>` | 로그 위치 변경 |
| `-TimeoutSec <초>` | 다운로드 타임아웃 (기본 900) |

```powershell
# 재설치
.\Install-HEVC.ps1 -Force

# 제거
.\Install-HEVC.ps1 -Uninstall

# 오프라인 설치 (USB 등에 번들 복사해 둔 경우)
.\Install-HEVC.ps1 -Offline -BundlePath .\packages\Microsoft.HEVCVideoExtension_2.4.149.0_neutral_~_8wekyb3d8bbwe.appxbundle
```

### 종료 코드

| 코드 | 의미 |
|---|---|
| 0 | 설치 완료 |
| 10 | 이미 설치됨 (변경 없음) |
| 20 | 이 PC에 맞는 번들을 못 찾음 |
| 21 | `-BundlePath` 경로가 없음 |
| 30 | 설치/제거 실패 |
| 40 | 지원하지 않는 OS (1709 미만) |

---

## 동작 방식

1. **프로파일링** — 레지스트리에서 빌드/UBR/에디션, 아키텍처, 로캘, GPU와 하드웨어 HEVC 디코딩 가능성(추정)을 읽습니다.
2. **후보 수집** — 아래 순서로 모읍니다.

   | 순위 | 소스 | 설명 |
   |---|---|---|
   | 1 | `local` | 스크립트 옆 또는 `.\packages` 안의 `*.appxbundle` |
   | 2 | `cache` | `%LOCALAPPDATA%\HEVC-Installer\cache` |
   | 3 | `github` | 이 저장소 최신 릴리즈의 `.appxbundle` 자산 |
   | 4 | `store` | Microsoft 배포 CDN (공개 카탈로그로 해석) |

3. **매니페스트 검사** — 번들(zip) → 아키텍처에 맞는 `.appx` → `AppxManifest.xml`을 읽어 `TargetDeviceFamily MinVersion`을 뽑습니다. 현재 빌드보다 높으면 **다운로드한 뒤에도 설치하지 않고 다음 후보로 넘어갑니다.**
4. **서명 검증** — `Get-AuthenticodeSignature`로 `O=Microsoft Corporation` 서명이 유효한지 확인합니다. 통과 못 하면 설치하지 않습니다.
5. **설치 & 검증** — `Add-AppxPackage` 후 패키지 상태가 `Ok`인지 다시 읽어 확인합니다.

로그: `%LOCALAPPDATA%\HEVC-Installer\install.log`

---

## 릴리즈 자산

| 파일 | 용도 |
|---|---|
| `HEVC-Video-Extensions-Installer-vX.Y.Z.zip` | 스크립트 + 문서 (압축 해제 후 실행) |
| `Microsoft.HEVCVideoExtension_2.4.149.0_...appxbundle` | Windows 10 ~ 11 24H2용 (오프라인 설치) |
| `Microsoft.HEVCVideoExtension_2.5.48.0_...appxbundle` | Windows 11 25H2(26200+)용 (오프라인 설치) |
| `SHA256SUMS.txt` | 체크섬 |

```powershell
Get-FileHash .\Microsoft.HEVCVideoExtension_2.4.149.0_neutral_~_8wekyb3d8bbwe.appxbundle -Algorithm SHA256
```

스크립트만 받아 실행하면 릴리즈 자산 또는 Microsoft CDN에서 알아서 내려받으므로, 번들을 직접 받을 필요는 없습니다.

---

## 문제 해결

| 증상 | 원인 / 대처 |
|---|---|
| `0x80073CFD` | 번들 요구 빌드 > 현재 OS. `-Diagnose`로 확인. 스크립트를 최신 버전으로 받으면 자동 회피됩니다. |
| `0x80073D02` | 사진/영화 및 TV 앱이 코덱을 잡고 있음. 앱 종료 후 `-Force`로 재시도. |
| `0x80073CF9` | `AppXSvc`(AppX Deployment Service)가 중지됨. `sc config AppXSvc start= demand` 후 재부팅. |
| `0x800B0109` | 서명 신뢰 실패. 회사 프록시의 TLS 검사 또는 루트 인증서 문제. |
| 설치 후에도 재생 안 됨 | Windows N 에디션이면 **Media Feature Pack** 설치 필요. 그래픽 드라이버가 오래됐으면 하드웨어 디코딩 실패로 끊길 수 있음. |
| Store가 계속 업데이트를 시도 | 무료판은 Store 자동 업데이트 대상이 아닙니다. 알림이 뜨면 무시해도 됩니다. |

급할 때 대안: [VLC](https://www.videolan.org/vlc/)는 자체 HEVC 디코더를 내장하고 있어 코덱 설치 없이도 재생됩니다. 다만 사진/영화 및 TV, 브라우저, 일부 편집 프로그램은 시스템 코덱이 필요합니다.

---

## 개발

```
Install-HEVC.ps1     메인 스크립트 (PowerShell 5.1+, Windows PowerShell 기준)
Install-HEVC.cmd     더블클릭용 래퍼 (실행 정책 우회 + 창 유지)
.github/workflows/   문법/정적 분석 CI, 태그 푸시 시 릴리즈 자동 생성
```

로컬 검증:

```powershell
# 문법만 검사
$errs = $null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\Install-HEVC.ps1), [ref]$null, [ref]$errs) | Out-Null
$errs

# PSScriptAnalyzer
Invoke-ScriptAnalyzer .\Install-HEVC.ps1 -Severity Error
```

---

## 고지

- 이 저장소의 스크립트는 MIT 라이선스입니다.
- HEVC 확장 패키지 자체는 **Microsoft Corporation**의 저작물이며, 릴리즈에 첨부된 `.appxbundle`은 Microsoft 배포 CDN에서 받은 **서명 원본 그대로**입니다. 재배포 권한은 Microsoft Store 약관을 따릅니다. 상업적 재배포 전에는 약관을 직접 확인하세요.
- 이 도구는 Microsoft와 무관한 비공식 도우미입니다.
