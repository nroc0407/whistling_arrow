# Whistling Arrow — Godot port

Godot 4.7.1의 Compatibility 렌더러를 사용하는 3D 후속 구현입니다. 기본 실행 장면은 `scenes/main_3d.tscn`이며, 최초 2D 포트는 `scenes/main.tscn`에 비교용으로 남아 있습니다. 기존 브라우저 기준 구현은 저장소 루트의 `whistling_arrow.html`과 `prototype-html-v1` 태그에 그대로 보존되어 있습니다. 최초 Godot 포트의 4.6.1 기록은 역사적 마일스톤으로만 보존되며, 현재 프로젝트 작업과 검증에는 사용하지 않습니다.

## 실행

1. Godot 4.7.1에서 이 `godot` 디렉터리의 `project.godot`을 엽니다.
2. 프로젝트를 실행하면 3D 아레나 장면이 시작됩니다. 2D 기준판을 확인하려면 `scenes/main.tscn`을 직접 실행합니다.
3. `Enable Mic & Start`를 누르고 운영체제 또는 브라우저의 마이크 권한을 허용합니다.

Web export에서 마이크를 쓰려면 결과물을 HTTPS 또는 localhost로 제공해야 합니다. 파일 탐색기에서 `index.html`을 직접 여는 방식은 지원 대상으로 삼지 않습니다.

현재 Web preset은 피치 분석 WorkerThreadPool을 위해 스레드 지원을 사용합니다. 배포 서버는 `Cross-Origin-Opener-Policy: same-origin`과 `Cross-Origin-Embedder-Policy: require-corp` 헤더를 제공해야 합니다.

## 디버그 조작

실제 마이크 없이도 게임 상태를 검증할 수 있습니다.

| 키 | 동작 |
| --- | --- |
| `1` | `RETURN` — 홈으로 복귀 |
| `2` | `FLOAT` — 관성 부유 |
| `3` | `ATTACK` — 최근접 과녁 자동추적 |
| `Numpad 7` | 최근접 과녁 고정 직행, 관통 순간 다음 과녁 자동 락온 및 연쇄 조준 테스트 |
| `Numpad 9` | 화살의 시작 원점인 홈 비콘으로 복귀 테스트 |
| `M` | 마이크 입력 시작/복귀 |
| `Space` | 마이크 없이 게임 시작 |

## 구성

- `scenes/main_3d.tscn`: 현재 기본 3D 아레나 장면
- `scripts/main_3d.gd`: 3D 월드와 기존 마이크·HUD 연결
- `scripts/game_world_3d.gd`: 3D 화살 비행, 적, 홈, 카메라와 절차적 시각물
- `scripts/game_config_3d.gd`: 3D 아레나와 비행 수치
- `scenes/main.tscn`: 보존된 2D 기준 장면과 680×680 게임 월드
- `scripts/main.gd`: UI·마이크·게임 월드 통합
- `scripts/game_world.gd`: 화살, 과녁, 홈, 충돌, 점수와 CanvasItem 렌더링
- `scripts/game_config.gd`: 게임 수치 중앙 관리
- `scripts/pitch_detector.gd`: 최신 마이크 창 리샘플링, 비동기 자기상관 피치 추정과 세 명령 분류
- `scripts/hud.gd`: HUD, 기준 Hz 슬라이더와 시작/재시작 화면
- `tests/`: 합성 음정 및 게임 상태 headless 테스트

## 자동 검증

저장소 루트에서 Godot 실행 파일 경로를 환경에 맞게 바꿔 실행합니다.

```powershell
godot --headless --path .\godot --script res://tests/test_pitch_detector.gd
godot --headless --path .\godot --script res://tests/test_game_world.gd
godot --headless --path .\godot --script res://tests/test_game_world_3d.gd
godot --headless --path .\godot --quit-after 10
```

## Web export

Godot Web export template이 설치되어 있다면 다음 명령으로 저장소 루트의 `build/godot-web`에 내보낼 수 있습니다. 빌드 폴더를 프로젝트 바깥에 두어 생성물이 다시 Godot 리소스로 포함되지 않게 합니다.

```powershell
godot --headless --path .\godot --export-release Web ..\build\godot-web\index.html
```

현재 루트 `vercel.json`은 기존 HTML 프로토타입을 계속 서비스합니다. Godot 빌드를 실제 배포 대상으로 전환하는 작업은 별도 배포 단계에서 수행합니다.
