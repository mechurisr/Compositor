# CLAUDE.md — Compositor

macOS용 Photoshop 대체 이미지 편집기 (Swift / SwiftUI / AppKit / Core Graphics / Core Image / Metal + C 픽셀 커널).
저장소: `robbietilton/Compositor` · 소스 약 40k 줄 · 앱 코드 `Compositor/`, 테스트 `CompositorTests/`(Swift Testing).

이 문서는 두 부분이다.

1. **[1부] 코드베이스 분석** — 문서·레이어 모델, 조정/필터 적용 경로, 선택 영역·마스크 표현, 되돌리기 구조.
2. **[2부] AI 어시스턴트 설계 계획** — JSON 명령으로 호출 가능한 `EditCommand` 계층. **2.11의 1단계(`query.*` + 카탈로그 + 패널)는 구현됐다 — 현황은 2.13.** 2단계 이후는 여전히 계획뿐이다.

## 빌드 · 테스트

```
xcodebuild -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' build
xcodebuild -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' test
```

Xcode 안에서 작업 중이면 `BuildProject` MCP 도구를 쓸 것. 빠른 확인은 `XcodeRefreshCodeIssuesInFile`.
샌드박스 엔타이틀먼트는 `Config/Compositor.entitlements` — **`com.apple.security.network.client`가 이미 켜져 있다**(Sparkle 자동 업데이트용). 즉 2부의 API 클라이언트는 엔타이틀먼트 변경이 필요 없다.

---

# 1부 — 코드베이스 분석

## 1.1 문서 · 레이어 모델

핵심 타입은 전부 `Compositor/Document/EditorSession.swift`에 있다.

| 타입 | 위치 | 성격 |
|---|---|---|
| `ImageLayer` | `EditorSession.swift:4` | 값 타입 `struct`. 레이어 하나 |
| `CanvasDocument` | `EditorSession.swift:62` | 값 타입 `struct`. 문서 전체 |
| `EditorSession` | `EditorSession.swift:103` | `@Observable final class`. 유일한 가변 허브 (약 944줄) |
| `ProjectTab` / `ProjectWorkspace` | `Document/ProjectWorkspace.swift:6`, `:20` | 탭마다 독립된 `EditorSession` + `ProjectController` |

`ImageLayer` 필드: `id`, `asset: ImportedImage?`, `transform: LayerTransform`, `name`, `isVisible`, `parentID`, `isGroup`, `opacity`, `blendMode`, `maskSourceID`, `mask: LayerMask?`, `adjustment: LayerAdjustment?`, `shape`, `effects`, `text`.

`CanvasDocument` 필드: `id`, `width`, `height`, `resolution`, `layers: [ImageLayer]`, `guides`, `selection: DocumentSelection?`.

### 반드시 알아야 할 불변식

- **레이어는 플랫 배열 + `parentID`로 계층을 만든다.** 트리 구조가 아니다. 배열 순서가 곧 **아래→위** 순서이고, 그룹은 연속된 subtree로 순회한다(`LayerHierarchy.entries`). 조상 중첩 한계 64.
- **폴더는 pass-through.** 그룹 안의 레이어는 하나의 단위로 합성된 뒤 아래에 얹히는 게 아니라, 바로 아래 픽셀 위에 직접 그려진다. 그래서 폴더 불투명도는 자식마다 곱해지고, 폴더 블렌드 모드는 항상 Normal이다.
- **`selection`이 문서 안에 있다**(`EditorSession.swift:71`). 되돌리기가 선택 영역 변경까지 덮기 때문이다. 단 디스크에는 저장되지 않는다.
- 좌표계는 **문서 픽셀, 좌상단 원점, y 아래로 증가**. `LayerTransform`(`Document/LayerTransform.swift:18`)은 회전 안 된 bounds(`origin`,`size`) + 중심 기준 **시계 방향** `rotation` + `flipX`/`flipY` + `sampling`. 스케일은 픽셀 재생성이 아니라 transform 변경이므로 비파괴적이다.
- `asset == nil`은 "빈 레이어" — 칠하기 시작할 때까지 픽셀을 할당하지 않는다(`EditorSession.swift:38`).
- 한계는 `Document/DocumentLimits.swift`: 한 변 30,000px, 문서 총 1억 소스 픽셀, 레이어 10,000장.

### 직렬화

`.comp`는 macOS 문서 패키지(`manifest.json` + `images/<UUID>.png`). 포맷 버전 **9**, 1–9 읽기 가능.

| 타입 | 위치 |
|---|---|
| `ProjectManifest` | `IO/ProjectStore.swift:13` |
| `ProjectLayerRecord` | `IO/ProjectStore.swift:33` |
| `ProjectSnapshot` | `IO/ProjectStore.swift:58` |
| `session.projectSnapshot()` | `Document/EditorSession+Projects.swift:4` |

**`docs/project-format.md`가 스키마의 정본이다.** 버전별로 어떤 필드가 추가됐고 무엇이 거부되는지 전부 서술돼 있다. 저장 포맷을 건드리면 이 문서와 `CompositorTests/PSDRoundTripTests.swift`·`ProjectTests.swift`를 함께 갱신해야 한다.

`ProjectLayerRecord`는 이미 `Codable`이고 이미 문서화된 스키마다 — **2부의 읽기 경로는 이걸 재사용한다.**

## 1.2 조정 · 필터 적용 함수

파이프라인이 **두 개** 있고, 세 번째로 둘을 잇는 브리지가 있다.

### (a) 비파괴 조정 레이어 — `Document/LayerAdjustment.swift`

- `AdjustmentKind`(`:4`): 12종 — Hue/Saturation, Levels, Curves, Exposure, Gradient Map, Grain, Add Noise, Gaussian Blur, Motion Blur, Invert, Black & White, Color Balance.
- `LayerAdjustment`(`:45`): `Codable`. 모든 종류의 설정을 한 구조체에 옵셔널로 담고, 없으면 항등 조정으로 해석한다(`resolvedHSV`, `gaussianRadius` 등 `resolved*` 프로퍼티들). 예전 프로젝트가 그대로 디코드되게 하려는 설계.
- **`LayerAdjustment.apply(_:region:scale:)`(`:144`) — 단일 픽셀 진입점.** 종류별로 `HueSaturationFilter` / `LevelsFilter` / `curves.apply` / `blackWhite.apply` / `colorBalance.apply` / `exposure.apply` / `gradientMap.apply` / `grain.apply` / `PixelFilter.run` / `PixelInvert.run`으로 분기한다.
- `isValid`(`:128`): 전 범위 검증. `samplingMargin`(`:121`): blur류가 dirty rect 밖을 샘플링할 때 필요한 여유 픽셀.
- 세션 명령: `addAdjustment(_:)`(`:184`), `updateAdjustment(_:value:)`(`:206`).

### (b) 파괴적 필터 — `Document/Filters.swift`

- `FilterKind`(`:7`): 16종 — 위의 색 조정 6종 + Vignette, Bloom/Glow, Tonal Contrast, Lens Correction, Camera Raw, Remove Background, Content-Aware Fill, Gaussian/Motion Blur, Add Noise.
- `FilterSettings`(`:40`) + **`normalized`(`:87`)** — 모든 값을 유효 범위로 클램프. `FilterJob`(`:121`)이 실행 단위.
- **`PixelFilter.run(_:)`(`:177`) — 단일 파괴적 진입점.** 끝에서 `job.selection`이 있으면 `PixelAdjust.blend(... through: selection ...)`로 선택 영역 안에만 합성한다(`:264`).
- `FilterEdit`(`:269`, `@Observable class`): 모달 라이브 프리뷰 세션. 프리뷰는 최대 2048px 축소본에서 렌더(`previewLimit`), blur는 레이어 경계 밖으로 퍼지므로 `grow(to:)`로 픽셀 격자를 키운다(`:392`).
- 명령 흐름: **`beginFilter(_:)`(`:470`) → `updateFilter(_:preview:)`(`:507`) → `commitFilter()` async(`:571`) 또는 `cancelFilter()`(`:560`)**. 커밋에서 값이 항등이면 undo 단계를 만들지 않고 취소처럼 닫는다(`:586`).
- Levels와 Hue/Saturation은 전용 패널: `beginLevels()`/`commitLevels()`(`Document/Levels.swift`), `beginHueSaturation()`/`commitHueSaturation()`(`Document/HueSaturation.swift`).

### (c) 브리지 — `Document/AdjustmentEditing.swift`

조정 레이어를 더블클릭하면 **파괴적 편집기 UI를 그대로 재사용하되 결과를 레이어 메타데이터에 쓴다**. `beginAdjustmentEditing(_:)`(`:6`)은 그 레이어 아래쪽만 보이게 한 스냅샷을 플래튼해서 샘플링용 이미지로 쓰고(`ImageExporter.shared.render`, `:21`), `previewAdjustmentEditing(preview:)`(`:101`)로 실시간 반영, `finishAdjustmentEditing(commit:)`(`:110`)에서 확정/복원한다.

### 설정 구조체 패턴 (검증 템플릿)

`Document/ImageAdjustments.swift`의 `ExposureSettings`(`:37`), `GradientMapSettings`(`:75`), `BlackWhiteSettings`(`:114`), `ColorBalanceSettings`(`:146`), `GrainSettings`(`:180`)는 모두 같은 형태다: **`static let ...Range` + `isValid` + `normalized` + `apply(_:)`**. `AdjustmentColor`(`:20`)는 0–1 sRGB.

픽셀 연산은 C 커널(`Rendering/AdjustPixels.c`, `LevelsPixels.c`, `NoisePixels.c`, `LensPixels.c`, …)이고 `ImageAdjustmentPixels.run(_:_:)`(`:6`)이 CGImage↔RGBA 버퍼 왕복을 감싼다. 브리징 헤더는 `Compositor/Compositor-Bridging-Header.h`.

> 2부의 검증은 **이 `isValid`/`normalized`를 재사용해야 한다.** 범위를 다시 적으면 반드시 어긋난다.

## 1.3 선택 영역 표현 — `Document/Selection.swift`

- **`DocumentSelection`(`:7`)**: `path: CGPath`(문서 좌표) + `antialiased: Bool` + `feather: CGFloat`(문서 픽셀). 래스터가 아니라 **경로**가 정본이다.
- **삼상 의미론 (중요)**: `document.selection == nil` = 선택 없음(= 전체 대상). `path`가 빈 selection = **명시적 빈 선택** — 이후 편집은 "아무것도 건드리지 않음"으로 취급해야 하고, 절대 "전체"로 해석해선 안 된다(`:4`–`:6` 주석).
- 래스터화: `coverage(width:height:)`(`:15`) → 8비트 그레이(흰색 = 선택), feather는 `applyingGaussianBlur(sigma: feather/2)`.
- **`clip(canvas:)`(`:39`) → `SelectionClip`(`:53`)** `{rect, coverage}` — 필터·브러시가 소비하는 형태. `apply(to:)`(`:58`)가 CGContext에 클립을 건다. `coverage == nil`이면 전부 잘라낸다.
- 불리언 연산: `applySelection(_:mode:name:)`(`:233`)에서 CGPath `union`/`subtracting`/`intersection`. `SelectionMode`(`:85`) = replace/add/subtract. Shift=add, Option=subtract(`:123`).
- **모든 변경은 `setSelection(_:name:)`(`:249`) 한 곳을 통과하고, 거기서 `beginEdit`/`endEdit`을 한다.**
- 명령: `selectAll`(`:344`), `deselect`(`:349`), `invertSelection`(`:354`), `expandSelection`(`:317`) / `contractSelection`(`:321`)(경로를 stroke해서 밴드를 합집합/차집합), `featherSelection`(`:325`)(제곱합 루트로 누적), `promptSelectionAmount`/`confirmSelectionAmount`(`:300`,`:305`).
- 관련 파일: `ObjectSelection.swift`(Select Subject / Object), `SelectionEdits.swift`, `SelectionClipboard.swift`, `FloatingSelection.swift`.

## 1.4 마스크 표현 — `Document/LayerMask.swift`

**서로 다른 메커니즘 세 가지**가 있다. 혼동하면 안 된다.

### 1) 래스터 레이어 마스크 — `LayerMask`(`:6`)

- `asset: ImportedImage`(**불변**, 8비트 grayscale, 알파 없음 — `isValid`(`:23`)), `isEnabled`, `placement: LayerTransform?`, `isLinked`.
- **흰색 = 드러냄, 검정 = 감춤**, 중간 회색 = 부분 커버리지.
- `placement == nil`이면 마스크가 레이어 자신의 픽셀 격자를 덮고 레이어 변형을 그대로 따라간다. `placement`가 있으면 마스크가 문서 위 독립 위치를 가진다(Photoshop의 unlink).
- `isLinked`: 링크되면 레이어와 함께 이동, 해제되면 각자 변형. `placement(movingLayer:to:)`(`:54`)가 그 규칙.
- `solid(revealing:)`(`:27`)은 **1×1 마스크**를 만든다 — 칠하기 전에 풀해상도 픽셀을 할당하지 않기 위한 최적화. 균일 마스크는 어디 있어도 같으므로 `placement`를 nil로 접는다(`:56`).
- 렌더러가 쓰는 형태: `clipImage(placement:over:width:height:limit:)`(`:110`) — 레이어 격자로 리샘플하고 `MaskPlacementCache`(`:130`, LRU 8개/64Mpx)에 캐시.
- 그룹도 마스크를 가진다(포맷 v6+).

### 2) 클리핑 마스크 (라이브 알파) — `ImageLayer.maskSourceID`

다른 레이어의 알파를 문서 좌표에서 곱한다. 소스의 픽셀·transform·불투명도·래스터 마스크·상위 라이브 마스크가 커버리지에 기여하고, **가시성과 RGB는 기여하지 않는다.** 자기 참조·순환·그룹 끝점·256노드 초과 체인은 거부. 구현은 `Document/LiveLayerMask.swift`, 삭제 시 베이킹은 `LiveMaskBaker`.

### 3) 폴더 마스크 — `FolderMaskClip`(`:172`)

폴더가 pass-through이므로 폴더 마스크는 **자손 레이어마다** 적용되어, 그 레이어 자신의 마스크와 더 바깥 폴더들의 마스크와 곱해진다(Core Graphics가 중첩 클립을 곱해준다). `draw(_:parent:clip:in:drawLayer:)`(`:191`)가 순회.

### 마스크 세션 명령

`canEditMask`(`:221`), `selectLayerTarget(_:mask:)`(`:222`), `addMask(revealing:)`(`:233`, 선택 영역이 있으면 그걸 써서 만들고 같은 undo 단계에서 선택 해제), `addLayerMask(revealing:)`(`:263`), `toggleLayerMask()`(`:272`), `deleteLayerMask()`(`:280`), `copyMask(from:to:)`(`:298`), `toggleMaskLink(_:)`(`:312`), `commitMaskTransform(_:)`(`:341`).

`session.isMaskSelected`(세션 전용, 저장 안 됨)가 **칠하기·반전이 픽셀에 갈지 마스크에 갈지**를 결정한다. Remove Background 필터는 픽셀을 지우지 않고 마스크로 커밋한다(`Filters.swift:647`).

## 1.5 되돌리기 — UndoManager를 쓰지 않는다

**문서 되돌리기에 `UndoManager`는 쓰이지 않는다.** 저장소 전체에서 `UndoManager`가 등장하는 곳은 단 한 군데다:

- `Rendering/InlineTextEditor.swift:7-8` — 인라인 텍스트 편집용 **비공개 텍스트 필드 UndoManager**. `override var undoManager` 로 NSTextView에 넘긴다. 문서 히스토리와 무관.

문서 되돌리기는 자체 구현인 **`DocumentHistory`**(`Document/DocumentHistory.swift:7`, `@Observable final class`)다.

- `Snapshot`(`:8`) = `{document: CanvasDocument?, activeLayerID: UUID?, revision: UUID}`. **값 스냅샷이고 불변 CGImage를 공유하므로 레이어 편집에 픽셀 복사가 없다**(`:5` 주석).
- **`begin(_:document:selection:)`(`:50`) / `end(document:selection:)`(`:58`)** 에 `depth` 카운터가 있어 **중첩 가능**하고, 가장 바깥 쌍만 기록한다. → 여러 편집을 하나의 undo 단계로 묶을 수 있다. **2부에서 핵심적으로 활용할 지점.**
- `end`는 `before.document != document` 비교로 **no-op 편집을 버린다**(`:64`). 선택/네비게이션이 redo 히스토리를 날리지 않게 하려는 것.
- `past`/`future` 배열. `entryLimit` 100, `retainedByteLimit` 256 MiB. `retainedBytes(current:)`(`:89`)가 라이브 문서가 참조하지 않는 이미지 바이트만 세고, `trim(current:)`(`:112`)가 개수·바이트 양쪽으로 축출.
- 더티 판정은 `revision` UUID vs `savedRevision` → `isModified`, `markSaved()`.

### 세션 래퍼 (`EditorSession.swift`)

| API | 위치 |
|---|---|
| `let history = DocumentHistory()` | `:567` |
| `beginEdit(_ name:)` / `endEdit()` | `:600` / `:604` |
| `undo()` / `redo()` / `restore(_:)` | `:576` / `:583` / `:588` |
| `canUseHistory` / `canUndo` / `canRedo` | `:569` / `:573` / `:574` |

메뉴 Undo/Redo는 `CompositorApp.swift:24`–`:46`. 텍스트 드래프트나 모달 편집이 열려 있으면 NSTextView의 `undo:`로 넘기고, 아니면 `session.undo()`를 부른다.

### beginEdit 호출 지점

`Compositor/` 안 **24개 파일**이 `beginEdit`을 호출한다. 관용구는 일관되게 다음 둘 중 하나다:

```swift
beginEdit("Rename Layer")
defer { endEdit() }
// ... document 변경 ...
```
```swift
beginEdit("Transform Layer")
document?.layers[index].transform = edit.draft
endEdit()
```

가장 많은 곳: `EditorSession.swift`(14), `LayerMask.swift`(8), `Guides.swift`(5), `LiveLayerMask.swift`(4), `LayerAppearance.swift`(4). 그 외 `SelectionClipboard`, `LayerGroups`, `TypeTool`, `Selection`, `LayerFlip`, `Filters`, `EditorSession+Brush`, `Levels`, `HueSaturation`, `LayerEffects`, `LayerAdjustment`, `LayerMerge`, `Distort`, `SelectionEdits`, `FloatingSelection`, `AdjustmentEditing`, `ImageResizer`, `ProjectWorkspace`, `NativeLayerList`.

**규칙: 문서를 바꾸는 코드는 예외 없이 `beginEdit`/`endEdit` 쌍 안에 있어야 한다.**

## 1.6 게이팅과 동시성 — 2부의 전제

`EditorSession`에는 "지금 이 작업을 시작해도 되는가"를 판정하는 술어들이 있고, 메뉴 항목들이 `.disabled(...)`로 이걸 그대로 쓴다.

| 술어 | 위치 |
|---|---|
| `canStartProjectOperation` | `EditorSession.swift:151` |
| `canUseHistory` | `EditorSession.swift:569` |
| `canEditLayers` | `EditorSession.swift:606` |
| `canTransform` | `EditorSession.swift:296` |
| `canEditSelection` / `canModifySelection` | `Selection.swift:120` / `:293` |
| `canEditMask` | `LayerMask.swift:221` |
| `canContentAwareFill` | `Filters.swift:467` |
| `canAdjustColors`, `canEditPixels`, `canCopyPixels`, `canMergeLayers`, … | 각 기능 파일 |

이들은 대체로 같은 것들을 검사한다: `isProjectBusy`, `isImporting`, `brushStroke`, `warpStroke`, `transformEdit`, `cropRect`, `gradientEdit`, `pixelMove`, `levels`, `hueSaturation`, `filterEdit`, `adjustmentEditingID`, `textDraft`, `renamingLayerID`, `selectionAmountOperation`, 각종 시트 플래그.

대기 메커니즘:

- `isProjectBusy`(`:119`) — 겹치는 편집을 즉시 차단. UI가 관찰하지 않는다(빠른 편집이 화면을 번쩍이지 않게). 대신 250ms 넘게 지속되면 `showsBusy`가 켜진다(`:134`).
- **`await waitForProjectAccess()`(`:166`)** / **`await waitForFileRequest()`(`:155`)** — `CheckedContinuation` 큐로 순서를 지킨다.
- 무거운 작업은 `Task.detached(priority: .userInitiated)`로 내보내고 결과만 MainActor로 가져온다(`Filters.swift:534`, `:610`).

### 기존 명령 카탈로그

**`CompositorApp.swift`의 `.commands { ... }` 블록(`:23`–`:320`)이 사실상 이미 존재하는 명령 목록이다.** 각 항목이 `이름 + session 메서드 하나 + 활성화 술어` 형태다. 메뉴: Undo/Redo, New/Open/Import, Save/Export, Edit(Cut/Copy/Paste/Fill/Content-Aware Fill), Select, Image, Filter, Layer. 단축키 커스터마이즈는 `UI/KeyboardShortcuts.swift` + `ShortcutSettings`.

2부의 `EditCommand`는 **이 표를 그대로 미러링**하는 것이 출발점이다.

### 테스트 방식

`CompositorTests/`는 Swift Testing이고, `@MainActor struct` 안에서 `EditorSession()`을 직접 만들어 메서드를 부르고 `document` 상태를 검증한다(`LayerTests.swift:5`–`:12`가 전형). 시트는 `session.confirmConversions`, `session.confirmRawDevelop` 같은 테스트용 훅을 주입해 우회한다. **2부의 명령 계층도 정확히 같은 방식으로 테스트 가능하다** — UI가 필요 없다.

---

# 2부 — AI 어시스턴트 / `EditCommand` 계층 설계 계획

> 목표: 사람과 AI가 **같은 문서를 번갈아 편집**하고, 사람이 모르는 부분은 AI에게 물어보면 AI가 바로 작업까지 할 수 있게 한다.
> 아래는 설계 계획이다. 구현 코드는 아직 없다.

## 2.1 설계 원칙

1. **새로운 변경 경로를 만들지 않는다.** `EditCommand`는 기존 `EditorSession` 메서드를 호출하는 얇은 어댑터다. 픽셀 로직·검증·undo를 재구현하면 사람 경로와 AI 경로가 갈라지고, 그 순간 이 기능은 신뢰할 수 없어진다.
2. **검증은 재사용한다.** `LayerAdjustment.isValid`, `FilterSettings.normalized`, `LayerTransform.isValid`, `CanvasDocument.validDimension`, `DocumentLimits`. AI가 앱 자신이 거부할 값을 써넣을 수 없게 된다.
3. **게이팅을 존중한다.** 메뉴가 `.disabled`로 쓰는 그 술어를 명령도 똑같이 검사한다. 사람의 제스처가 진행 중일 때 AI가 문서를 건드리면 안 된다. 이게 안전한 교대(handoff)의 핵심이다.
4. **AI의 한 턴 = 하나의 undo 단계.** `DocumentHistory`의 `depth` 중첩(`DocumentHistory.swift:51`–`:56`)이 이미 이걸 공짜로 해준다. 바깥에서 `beginEdit` 한 번 감싸면 내부 호출들의 쌍이 하나로 접힌다. **⌘Z 한 번으로 AI 작업 전체를 되돌릴 수 있다는 것이 이 기능의 가장 중요한 UX 결정이다.**
5. **읽기와 쓰기를 분리한다.** 질의 명령은 undo 단계를 만들지 않고 게이팅도 느슨하다.

## 2.2 파일 배치 계획

```
Compositor/Assistant/
  EditCommand.swift          # 명령 enum + 페이로드 struct들 + LayerRef
  EditCommandCatalog.swift    # 기계가 읽는 스키마 (프롬프트/툴 정의 생성원)
  EditCommandRunner.swift     # @MainActor 실행기: 게이팅 → 검증 → 실행 → 결과
  DocumentDigest.swift        # 모델에게 보낼 읽기 전용 문서 JSON 뷰
  PNGEncoding.swift           # 썸네일/캔버스 렌더 PNG 인코딩 헬퍼
  CompositorTool.swift        # FoundationModels `Tool` 두 개(InspectDocumentTool·EditLayerTool) + CompositorToolBackend
  EditCommandRunner+Edits.swift # 2단계: propose / applyBatch / layerEditBlocker
  AssistantSession.swift      # @Observable 대화 상태 + LanguageModelSession 래퍼
Compositor/UI/
  AssistantPanel.swift        # 채팅 패널 (FloatingPanelController로 표시)
CompositorTests/
  EditCommandTests.swift
  EditCommandCatalogTests.swift
  AssistantSessionTests.swift
```

`EditorSession`을 더 키우지 않기 위해 별도 폴더로 둔다. `EditorSession`에 필요한 변경은 **`DocumentHistory.revision`을 읽기 전용으로 노출하는 것 하나뿐**(현재 `private`)이다 — 2.7의 낙관적 동시성에 쓴다. **구현됨: `private(set)`.**

> **아키텍처 변경 (2.13에서 상세)**: 원래 계획한 `AssistantClient.swift`(Anthropic Messages API 직접 호출)는 만들지 않았다. 대신 macOS의 `FoundationModels`(온디바이스 모델, API 키·네트워크·서버 불필요)를 기본 백엔드로 썼다. Anthropic 같은 클라우드 모델은 "업그레이드" 경로로 나중에 붙일 수 있는데, `FoundationModels`가 `LanguageModel`/`LanguageModelExecutor` 프로토콜로 커스텀 백엔드를 같은 `LanguageModelSession` API에 꽂을 수 있게 해준다 — 그러면 도구들(`CompositorTool.swift`)/`AssistantPanel`을 그대로 재사용하면서 `model:` 파라미터만 바뀔 가능성이 있다. **아직 설계·구현 안 됨.**

## 2.3 와이어 포맷

Anthropic tool use의 `input`에 1:1로 대응하도록 **중첩형**을 쓴다.

```json
{ "command": "layer.setOpacity", "arguments": { "layer": { "name": "Sky" }, "opacity": 0.6 } }
```

```swift
enum EditCommand: Sendable {
    case layerSetOpacity(LayerSetOpacity)
    case adjustmentAdd(AdjustmentAdd)
    case filterApply(FilterApply)
    case selectionModify(SelectionModify)
    // ...
}
```

`init(from:)`에서 `command` 문자열로 분기하고, 각 페이로드는 자기 `Codable` struct + `validate()`를 갖는다. 디코드 실패는 **기대 스키마를 담은 구조화된 에러**로 돌려보내 모델이 스스로 고치게 한다.

### 레이어 지정

AI가 처음부터 UUID를 알 수는 없다. 해석 가능한 참조를 둔다.

```swift
enum LayerRef: Codable, Sendable {
    case id(UUID)
    case name(String)      // 중복이면 ambiguous 에러
    case active
    case index(Int)        // 아래→위, 배열 순서와 동일
}
```

**결과에는 항상 해석된 UUID를 되돌려준다** — 다음 명령은 정확히 지정할 수 있다.

## 2.4 명령 패밀리

`CompositorApp.swift`의 메뉴 표를 미러링한다.

| 패밀리 | 명령 예 | 위임 대상 |
|---|---|---|
| `query.*` | `describeDocument`, `describeLayer`, `renderCanvas`, `getHistory`, `getCapabilities` | `projectSnapshot()`, `ImageExporter` |
| `document.*` | `create`, `canvasSize`, `imageSize`, `trim`, `flipCanvas` | `ProjectController`, `session.flipCanvas` |
| `layer.*` | `add`, `addGroup`, `delete`, `rename`, `move`, `setVisibility`, `setOpacity`, `setBlendMode`, `duplicate`, `merge`, `group` | `EditorSession.swift`, `LayerGroups`, `LayerMerge`, `LayerAppearance` |
| `transform.*` | `set`, `nudge`, `flip` | `beginTransform`/`previewTransform`/`commitTransform` |
| `adjustment.*` | `add(kind, settings)`, `update(layer, settings)` | `addAdjustment`, `updateAdjustment` |
| `filter.*` | `apply(kind, settings)` — begin+update+commit을 한 명령으로 접음 | `beginFilter`→`updateFilter`→`await commitFilter` |
| `selection.*` | `all`, `deselect`, `invert`, `rect`, `ellipse`, `layerPixels`, `subject`, `expand`, `contract`, `feather` | `Selection.swift`, `ObjectSelection.swift` |
| `mask.*` | `add(white/black/fromSelection)`, `toggle`, `delete`, `invert`, `setLinked`, `clippingMask` | `LayerMask.swift`, `LiveLayerMask.swift` |
| `effects.*` | `add`, `update`, `remove` | `LayerEffects.swift` |
| `pixels.*` | `fill(color)`, `clear` | `fillSelection`, `clearSelectedPixels` |
| `history.*` | `undo`, `redo` | `session.undo()` / `redo()`, `canUseHistory` 게이팅 |

**1단계에서 제외**(2.9 참조): 브러시 스트로크, Camera Raw 개별 슬라이더, PSD 입출력, 저장/내보내기.

## 2.5 실행기 파이프라인

```swift
@MainActor
final class EditCommandRunner {
    let session: EditorSession
    func run(_ command: EditCommand) async -> EditCommandResult
    func run(_ batch: EditBatch) async -> EditBatchResult
}
```

명령 하나당 순서:

1. **디코드** → 타입 있는 페이로드. 실패 시 기대 스키마 첨부.
2. **검증** → 기존 `isValid`/`normalized` 재사용. 클램프했으면 `warnings[]`에 남긴다(조용히 값을 바꾸면 안 된다).
3. **게이팅** → 해당 메뉴 항목과 같은 술어. 일시적 바쁨이면 `await session.waitForProjectAccess()`로 기다리고, 사람이 무언가를 열어둔 상태면 **무엇이 막고 있는지 이름을 담아** 실패시킨다(`"a transform is pending"`, `"a text draft is open"`).
4. **`LayerRef` 해석** → UUID.
5. **실행** → 기존 세션 메서드 호출. 모달 편집기는 begin→update→commit 전체를 `await`로 구동.
6. **결과** → `{ ok, undoName, resolvedIDs, warnings[], digestDelta }`. 실패는 `{ ok: false, code, message, hint }`.

### 배치와 원자성

```swift
struct EditBatch: Codable { let label: String; let commands: [EditCommand]; var atomic = true }
```

`atomic == true`면 바깥에서 `beginEdit("AI: \(label)")` 한 번 → 내부 쌍들이 `depth`로 접혀 **undo 단계 하나**가 된다. 중간 실패 시 `session.undo()` 한 번으로 전체를 되돌리고 부분 실패 보고서를 반환한다. `DocumentHistory`가 문서 전체를 값으로 스냅샷하기 때문에 이게 그냥 동작한다.

**AI 턴의 기본값은 `atomic: true`로 한다.**

## 2.6 읽기 경로 — `DocumentDigest`

모델이 상태를 싸게 볼 수 있어야 한다. **`projectSnapshot()` → `ProjectManifest`가 이미 `Codable`이고 이미 `docs/project-format.md`로 문서화된 스키마**이므로 그걸 재사용한다.

- `query.describeDocument` → manifest JSON에서 이미지 바이트를 뺀 것 + 세션 전용 상태(`activeLayerID`, `isMaskSelected`, 선택 영역의 bounds/feather/비었는지, `tool`, `history.undoName`, `undoCount`, revision).
- `query.describeLayer(includeThumbnail:)` → 요청 시에만 `ImportedImage.thumbnail`을 base64 PNG로. 기본은 끔(토큰 비용).
- `query.renderCanvas(maxSide:)` → `ImageExporter.shared.render(snapshot)`로 플래튼한 뒤 축소해 이미지 블록으로 첨부. **"이거 왜 이상해 보여?"류 질문에 AI가 실제로 답할 수 있게 하는 부분이고, "모르는 부분을 물어본다"는 요구를 실현하는 핵심이다.** `AdjustmentEditing.swift:21`이 이미 같은 렌더 경로를 쓴다.

## 2.7 프롬프트와 카탈로그

`EditCommandCatalog`를 단일 정본으로 둔다. 명령마다 `이름 / 한 줄 설명 / 인자 스키마(범위 포함) / 전제조건(평문)`. 여기서 Anthropic tool 정의를 **생성**한다 — 프롬프트와 실행기가 어긋날 수 없게.

> 테스트: 모든 `EditCommand` 케이스가 카탈로그에 있고 그 역도 성립하는지 검사(`EditCommandCatalogTests`). 드리프트 방지 장치.

시스템 프롬프트에 반드시 넣을 **비자명한 불변식** (1부에서 드러난 것들):

- 좌표계: 문서 픽셀, 좌상단 원점, y 아래로, 회전은 시계 방향.
- 레이어 배열은 **아래→위**, 계층은 `parentID` 플랫 배열.
- 선택 영역: `nil`(전체) vs **빈 선택**(아무것도) 구분.
- 마스크: **흰색 = 드러냄**. 그리고 **메커니즘이 세 가지**(래스터 마스크 / `maskSourceID` 클리핑 / 폴더 마스크)라는 점.
- 폴더는 pass-through — 폴더 마스크·불투명도는 자손마다 곱해진다.
- 스케일은 비파괴(transform), 필터는 파괴적(픽셀 교체).
- 조정 레이어는 **자기 폴더 안에서 자기 아래에 합성된 것들**에만 영향을 준다.

## 2.8 교대(handoff) 모델

`AssistantSession` 상태: `idle` → `thinking` → `awaitingApproval` → `applying` → `idle`, 그리고 캔버스 제스처·모달이 열려 있으면 `humanControl`.

- 실행기가 이미 `canStartProjectOperation`에서 블록되므로, **그 상태를 패널에 그대로 비춘다** — AI가 실패하는 게 아니라 "차례를 기다리는" 것으로 보이게.
- **기본은 제안 모드**: AI가 배치를 제안하고, 패널이 사람이 읽을 수 있는 목록으로 보여주고("'Sky' 위에 Levels 조정 레이어 추가 · 블랙 포인트 12"), 사람이 Apply를 누른다.
- 자동 적용 모드에서도 **되돌리기 부담이 큰 명령은 항상 승인을 요구**한다: 삭제, 병합/플래튼, 캔버스 리사이즈, 저장/내보내기.
- 적용 후 `undoName`을 기록해 "그거 취소해" = `history.undo` 명령으로 처리.
- **사람이 중간에 편집한 경우**: 매 digest에 `history.undoCount`와 문서 revision을 담고, 모델이 계획의 근거가 된 revision을 에코하게 한다. 적용 시점에 revision이 다르면 재계획. 저렴한 낙관적 동시성이고, 이것 때문에 `DocumentHistory.revision`을 읽기 전용으로 노출해야 한다.

## 2.9 통합 지점

- `ProjectTab`(`ProjectWorkspace.swift:6`)에 `session`/`controller` 옆에 `assistant: AssistantSession`을 추가 — **탭마다 독립 대화**. 기존 탭별 소유 구조와 일치한다. **구현됨**: `ProjectTab.assistant`. `ContentView`는 `.id(tab.id)`로 탭 전환마다 재생성되므로 어시스턴트를 만들면 안 되고 받기만 한다. 패널은 화면에 하나 — 열려 있으면 `ProjectWorkspace.selectedID`의 `didSet`(`handOffAssistantPanel`)이 이전 탭 패널을 닫고 새 탭 패널을 연다(`FloatingPanelController`는 해제돼도 패널을 닫지 않으므로, 이걸 안 하면 이전 탭 문서에 대해 답하는 패널이 남는다).
- 패널은 `ProjectWorkspaceView` / `ContentView.swift`에 사이드바로. **구현은 사이드바가 아니라 기존 `FloatingPanelController` 패턴**(Levels/Hue-Saturation/Keyboard Shortcuts와 동일) — 툴바의 sparkles 아이콘이 토글한다.
- API 키는 Keychain. 네트워크 엔타이틀먼트는 **이미 켜져 있다**(`Config/Compositor.entitlements`). **온디바이스 기본 경로는 키·네트워크가 전혀 필요 없다** — 이 항목은 Anthropic 업그레이드 경로에만 해당.

## 2.10 테스트 계획

기존 방식 그대로, UI 없이 가능하다.

- `EditorSession()` + `createDocument` → JSON 명령 실행 → `document` 상태 검증. 배치마다 `session.history.undoCount == 1`이고 `session.undo()`가 완전히 복원하는지.
- 모든 명령의 JSON 왕복 디코드. 카탈로그 커버리지.
- **게이팅 테스트**: `session.textDraft` / `transformEdit` / `isProjectBusy`를 세팅해두고, 명령이 문서를 바꾸는 대신 올바른 에러 코드로 거부하는지.

## 2.11 단계별 진행

| 단계 | 범위 | 상태 |
|---|---|---|
| 1 | `query.*` 전용(변경 없음) + 카탈로그 + 패널. digest와 프롬프트의 타당성을 먼저 증명한다. | **구현됨 — 2.13** |
| 2 | `layer.*`, `selection.*`, `mask.*`, `adjustment.*` + 원자적 배치 + 승인 UI. | **2a·2b·2c 구현됨**(`layer.*`, `selection.*`, `mask.*` + 배치 + 승인 UI) — 2.14. `adjustment.*`는 계획만 |
| 3 | `filter.*`(비동기 모달 구동), `effects.*`, `transform.*`. | 계획만 |
| 4 | `pixels.*`, 브러시, 내보내기. | 계획만 |

## 2.12 위험과 미결정 사항

- **브러시 스트로크**를 명령으로 노출하는 건 표면이 크다(`BrushStroke.swift` 902줄, 비동기·상태 유지). 4단계로 미룬다.
- **Camera Raw**는 하위 섹션이 10개쯤 된다. 슬라이더별 명령이 아니라 `cameraRaw` 설정 blob 하나로 노출한다.
- **토큰 비용**: digest 크기, 썸네일, 캔버스 렌더. 매 턴 전체 캔버스를 보내지 않는다.
- **오프라인 앱에 네트워크가 들어온다**는 점 자체를 사용자에게 명시해야 한다(API 키·전송 내용).
- 파괴적 필터는 레이어 픽셀을 교체한다 — `DocumentHistory`의 256 MiB 보존 한계(`DocumentHistory.swift:28`)에 AI의 연속 작업이 빨리 닿을 수 있다. 배치를 원자적으로 묶는 것이 여기서도 도움이 된다.

## 2.13 구현 현황 — Stage 1 (2026-09-24, `ai-assistant` 브랜치)

Stage 1(`query.*` + 카탈로그 + 패널)이 끝까지 구현되고 실기기에서 실제 모델 응답까지 확인됐다(2026-10-10 갱신). 아래는 계획(2.1–2.12) 대비 실제로 달라진 점과 남은 일이다.

### 구현된 파일

| 파일 | 내용 |
|---|---|
| `Assistant/EditCommand.swift` | `EditCommand` enum(현재 `query.*` 5종만), `LayerRef`, `EditCommandError`(`code`/`message`/`hint`). JSON 와이어 포맷은 2.3 그대로. |
| `Assistant/EditCommandCatalog.swift` | `CommandDescriptor` 배열. `EditCommandCatalogTests`가 카탈로그↔디코더 드리프트를 잡는다. |
| `Assistant/DocumentDigest.swift` | `DocumentDigest`/`LayerDigest`/`HistoryDigest`/`SelectionDigest`/`CanvasRenderDigest`. `ProjectManifest`를 그대로 재사용(2.6 계획대로). |
| `Assistant/PNGEncoding.swift` | 캔버스 렌더 다운스케일 + PNG/base64 인코딩 (계획엔 없던 파일 — `ImageExporter`의 렌더 자체는 재사용하고, 리사이즈·인코딩만 새로 얇게 얹었다). |
| `Assistant/EditCommandRunner.swift` | `@MainActor final class EditCommandRunner: @unchecked Sendable`. `run(_:)`은 타입 있는 `EditCommand`를 받고, **`runJSON(command:argumentsJSON:)`이 실제 진입점**(아래 참고). |
| `Assistant/CompositorTool.swift` | (Stage 1 당시) `FoundationModels.Tool` 하나. `command`(String) + `argumentsJSON`(String)만 받아 `runJSON`으로 넘긴다. **2단계에서 타입 있는 도구 두 개로 바뀌었다 — 2.14.** 예외는 `query.renderCanvas` 하나 — 렌더한 `CGImage`를 `CanvasImageMailbox`에 맡기고 텍스트만 돌려준다(아래 "온디바이스 모델의 함정" 1). |
| `Assistant/AssistantSession.swift` | `@MainActor @Observable`. `SystemLanguageModel.default.availability` 체크 → `LanguageModelSession(tools:instructions:)`. `messages`/`submit(_:)`로 채팅 상태, `showPanel()`/`closePanel()`/`togglePanel()`로 자기 `FloatingPanelController` 소유. 한 턴에 모델을 최대 3번 부른다: 도구 대화 → (메일박스에 캔버스가 있으면) 이미지를 직접 첨부해 재질문 → (답이 사용자 언어가 아니면) 도구 없는 세션으로 번역. |
| `UI/AssistantPanel.swift` | 최소 채팅 SwiftUI 뷰. 가용성 배너 + "다시 확인" 버튼 + 메시지 목록 + 입력창. |
| `Document/DocumentHistory.swift` | `revision`을 `private var` → `private(set) var`로. |
| `ContentView.swift` | `@State private var assistant: AssistantSession`을 커스텀 `init`에서 `session`으로 생성. 툴바 `.primaryAction`에 sparkles 아이콘 버튼 → `assistant.togglePanel()`. |
| `CompositorTests/EditCommandTests.swift`, `EditCommandCatalogTests.swift`, `AssistantSessionTests.swift` | 아래 참고. |

### 계획과 달라진 점

1. **`AssistantClient.swift`(Anthropic HTTP 클라이언트)를 만들지 않았다.** 대신 macOS `FoundationModels`(온디바이스 모델)를 기본 백엔드로 썼다 — **API 키·네트워크·서버 비용 전혀 없이 "무료 기본값"을 만들 수 있어서.** `SystemLanguageModel.default.availability`가 `.available`/`.unavailable(reason)`을 주고, 안 되면 이유를 그대로 패널에 보여준다(기기 미지원/Apple Intelligence 꺼짐/모델 준비 중).
2. **명령마다 `Tool`을 만들지 않고 `Tool` 하나(`CompositorTool`)로 접었다.** (2.14에서 `{command, argumentsJSON}` 문자열 방식은 폐기 — 온디바이스 모델이 문자열 속 JSON을 만들지 못했다.) Apple 문서가 "요청당 툴 3–5개"를 권장하는데 Stage 1만 해도 5개 명령이라 명령마다 툴을 만드는 건 이 한도를 바로 넘는다. `CompositorTool.Arguments`는 `{command, argumentsJSON}` 뿐이고, 실제 스키마 검증은 여전히 `EditCommand`의 `Decodable`이 한다 — 2.1의 "새 변경 경로를 만들지 않는다" 원칙과 같은 이유로, 이 얇은 어댑터도 두 번 만들지 않았다.
3. **`EditCommandRunner`에 `runJSON(command:argumentsJSON:)`이 추가됐다** — 문자열 in/out, `FoundationModels`를 import하지 않는다. 모델의 tool call이 실제로 거치는 경로이면서, 모델 없이도(`EditCommandTests`) 테스트할 수 있는 이유다.
4. **패널은 사이드바가 아니라 `FloatingPanelController`**(기존 Levels/Hue-Saturation/Keyboard Shortcuts와 같은 패턴)로 구현했다. 소유는 2.9 계획대로 `ProjectTab.assistant`(2026-10-10).
5. **결과 컨트랙트가 2.5와 조금 다르다.** 쓰기 명령이 아직 없어서 `undoName`/`digestDelta`는 없고, `runJSON`은 `{ok, output}` 또는 `{ok:false, errorCode, errorMessage, errorHint}`만 돌려준다. 쓰기 패밀리가 들어올 때 `undoName`/`resolvedIDs`/`warnings`를 추가해야 한다.
6. **디코드는 `EditCommandRunner.decode(command:argumentsJSON:)` 한 곳**이고, 실패 봉투는 `EditCommandRunner.failureJSON(_:)`이 만든다. 특정 명령을 특별 취급하는 호출자(`CompositorToolBackend`의 renderCanvas·편집 제안)도 이 둘을 거쳐야 한다 — 직접 JSON을 디코드하거나 문자열 보간으로 에러 JSON을 만들지 말 것.

### 온디바이스 모델의 함정 (2026-10-10 실측 — 2단계 이후 지시문·도구를 바꿀 때 반드시 재확인)

문서에 없는 동작이라 실험으로 확인했다. 지시문을 바꿀 때마다 실모델로 다시 측정할 것.

1. **도구 출력 속 이미지는 모델에게 전달되지 않는다.** 도구가 `Prompt { Attachment(image) }`를 돌려주면 transcript에는 첨부가 남지만, 모델은 보지 못하고 지어낸다(파랑·초록·노랑 단색을 모두 "Red"라고 답함). 같은 이미지를 프롬프트에 직접 첨부하면 정확히 맞힌다. → `CanvasImageMailbox` 우회: 도구는 이미지를 맡기고 "다음 메시지로 온다"는 텍스트만 반환, `AssistantSession`이 같은 세션에서 이미지를 직접 첨부해 한 번 더 묻는다(턴당 1회). 비전 미지원 모델(`capabilities.contains(.vision) == false`)에 첨부하면 `unsupportedCapability`로 턴 전체가 실패하므로 그 경우는 크기만 반환.
2. **지시문에 언어 이름을 쓰면 한국어 질문에서 도구 호출이 멈춘다.** "You MUST respond in Korean"(또는 "final reply in Korean", 프롬프트 끝의 "(Answer in Korean.)") + 한국어 질문 → 도구 호출 0/3, 대신 호출 계획·JSON을 답변 텍스트로 쓰거나 답을 지어낸다. 영어 질문이거나 언어 지시가 없으면 3/3. → 도구 세션에는 "Always reply in the same language the person writes in."만 넣고(이름 없이), 최종 답을 `NLLanguageRecognizer`로 확인해 사용자 언어가 아니면 **도구 없는 별도 세션**에서 번역한다(`localized(_:)`). 측정: 한국어 질문 6개 → 도구 6/6, 한국어 답 6/6. 번역 품질은 가끔 어색하다(일본어 문자 혼입 1회 관찰).
3. 앱 현지화가 `en`뿐이라 `Locale.current`는 한국어 사용자에게도 영어(`en_KR`)로 잡힌다. 사용자 언어는 `Locale.preferredLanguages.first`로 읽는다.

### 테스트

`EditCommandTests`(13개) + `EditCommandCatalogTests`(3개) + `AssistantSessionTests`(5개) — 전부 통과. `AssistantSessionTests`는 `SystemLanguageModel.default.availability`를 먼저 확인하고, `.available`이 아니면 해당 분기를 건너뛴다(Apple 공식 가이드가 권장하는 fallback 패턴과 동일) — CI나 Apple Intelligence가 꺼진 머신에서도 플레이키하지 않다. 실모델 테스트: 파란 캔버스의 색을 맞히는지(`seesTheCanvasColorWhenVisionIsAvailable`), 한국어 질문이 도구를 거쳐 한국어로 답하는지(`answersKoreanQuestionsInKoreanUsingTools`). 조건이 안 맞으면 조용히 통과하므로, 실제로 돌았는지는 실행 시간(수 초)으로 확인할 것.

### 실기기 확인 상태 (2026-10-10)

- M4 MacBook Air, macOS 27. 모델 `.available`, capabilities = vision + toolCalling + guidedGeneration.
- 실제 일러스트 문서에 "캔버스에 뭐가 보여?" → 수련·코이·검은 고양이·"Nujabes Vibes" 글자까지 한국어로 정확히 설명.
- Xcode `RunCodeSnippet`이 실행 중인 앱과 겹치면 SwiftUI 창 레이아웃에서 간헐적으로 크래시한다(앱 코드와 무관, 재실행하면 통과).

### Stage 1 남은 일

- ~~`ProjectTab`에 `assistant` 이전 — 탭별 대화 분리 (2.9)~~ → 완료. 테스트: `ProjectWorkspaceTests.eachTabKeepsItsOwnAssistant`, `assistantPanelFollowsTheCurrentTab`.
- 패널이 마크다운을 렌더하지 않는다(`**`가 그대로 보임).
- Anthropic(또는 다른 클라우드 모델) 업그레이드 경로 설계 — `LanguageModel`/`LanguageModelExecutor` 커스텀 백엔드로 `AssistantSession`과 도구들을 그대로 재사용할 수 있는지 검증.
- API 키 저장 방식(Keychain) — 업그레이드 경로를 실제로 만들 때.

## 2.14 구현 현황 — Stage 2a: `layer.*` + 제안/승인 (2026-10-10)

### 무엇이 있나

- **명령**: `layer.add`(이름 선택), `layer.rename`, `layer.setVisibility`, `layer.setOpacity`(0–1, 범위 밖은 거부 — 클램프 안 함), `layer.setBlendMode`(대소문자 무시, 폴더는 거부), `layer.delete`(라이브 마스크 소스는 거부 — `deleteLayer`가 Bake/Remove Links 모달을 띄우기 때문).
- **제안 모드(2.8)**: 모델의 편집 호출은 실행되지 않는다. `EditCommandRunner.propose`가 검증하고 승인 카드용 한국어 요약을 만든 뒤 `ProposalCollector`에 쌓는다. `.active`/`.index` 참조는 제안 시점의 id로 **고정(pin)** — 승인한 것이 그대로 실행된다. 같은 제안 안에서 `add`/`rename`이 만들 이름은 `pendingNames`로 미리 참조 가능. 같은 레이어의 같은 setter는 나중 것이 앞의 것을 대체(`supersedingKey`).
- **적용**: `applyBatch`가 바깥 `beginEdit("AI: …")`로 감싸 **undo 한 단계**. 실패하면 중단하고 `session.undo()`로 되돌린다(부분 단계가 redo 스택에 남는 건 감수). 세션 메서드는 가드에 걸리면 조용히 반환하므로 실행 후 문서를 확인해 `not_applied`로 보고.
- **게이팅**: `EditorSession.layerEditBlocker` — `canEditLayers` 조건을 하나씩 이름 붙여 미러링(둘을 함께 유지할 것) + `opacityEditLayerID`(불투명도 드래그 중이면 `setLayerOpacity`가 활성 레이어가 아니라 드래그 중인 레이어에 쓴다). `busy`면 제안을 남겨 두고 나중에 다시 적용 가능.
- **낙관적 동시성**: 제안 시점 `history.revision`을 기록, 적용 시 다르면 적용 안 함. 결과(적용/취소/실패/거부)는 다음 메시지 앞에 영어 메모로 모델에게 전달(`proposalOutcomeNote`).
- **UI**: `AssistantPanel`의 `ProposalCard` — 요약 목록, 삭제는 빨간색, 경고는 주황색, 적용/취소.
- **우회 차단**: `run`/`runJSON`에 편집 명령이 오면 `not_supported` — 승인 없이 실행되는 경로는 없다.

### 도구 설계 — 실측으로 바뀐 것 (온디바이스 모델, 한국어 요청, 각 2–3회)

1. **`{command, argumentsJSON}` 문자열 도구 폐기 → 타입 있는 `@Generable` 도구 두 개**: `InspectDocumentTool`(`query` enum: describeDocument/renderCanvas/getHistory), `EditLayerTool`(`action` enum + `layer` + `value`). 문자열 방식에서 모델은 `argumentsJSON`을 `"{"`에서 잘라 보내거나 `query.layer.setOpacity` 같은 이름을 지어냈다 — 정답 제안 **3/10**. 타입 도구로 **6/10 → 12/15**. 타입 인자는 와이어 포맷으로 되돌려 `CompositorToolBackend.handle` → `EditCommandRunner.decode` 한 경로를 그대로 탄다.
2. **값은 `value` 문자열 하나**: 동작별 옵셔널 필드(`name`/`opacity`/`blendMode`, blendMode를 enum으로 해도)를 주면 모델은 `blendMode`를 **한 번도 채우지 않고** 이름 칸에 "Layer 1 - Multiply"를 썼다(블렌드 0/6). `value` 하나로 바꾸자 3/3. 불투명도는 도구에서 퍼센트("50", "50%"; 1 이하 소수는 비율)로 받는다(`EditLayerTool.opacity(from:)`).
3. **`show`/`hide`를 별도 action으로**: 범용 이름일 때 "숨겨줘"에 `layer.delete`를 제안한 적이 있다. 분리 후 6/6.
4. **모델용 `describeLayer` 제거**: 레이어 이름 없이 불러 "not found"를 받고 "레이어가 없다"고 결론 내렸다. `describeDocument`가 모든 레이어를 담는다.
5. **모델은 도구 에러를 받으면 재시도하지 않는다** — 거의 항상 포기하고 답한다. 에러 문구를 잘 쓰는 것보다 처음부터 맞게 부르게 하는 게 중요. `LayerRef`가 문자열(이름/UUID)·정수(인덱스) 축약형도 받는 이유.
6. **조사 붙은 한국어 이름은 번역·변형된다**: "배경으로" → "Background"/"背景", "하늘로" → "hallo"/"hail"/"himmel"(0/6). 따옴표로 감싼 '인물'은 3/3 정확. 지시문("번역하지 말 것")으로 안 고쳐짐. → 이름이 사용자 메시지에 없으면 승인 카드에 경고를 단다(`ProposalCollector.unrequestedName`, 6/6 탐지). 모델에게도 알리지만 재호출은 0/6. **실질적 해결은 카드의 이름 칸**: add/rename 항목에 이름 입력칸이 있고, 고치면 `EditCommandRunner.renamingProposedLayer`가 같은 제안 안에서 옛 이름을 가리키던 뒤의 편집까지 새 이름으로 바꾼 뒤 제안 전체를 `propose`로 다시 검증한다(id 유지, 고친 항목의 경고 제거). 입력 중인 값은 적용 버튼을 누를 때 먼저 반영되고, 유효하지 않으면 적용하지 않는다.

측정 결과 요약: 불투명도 3/3, 숨기기 3/3, 블렌드 3/3, 추가 3/3, 이름 변경(따옴표) 3/3·(조사) 0/6 — 단 오답은 전부 카드에서 경고.

### 테스트

`EditCommandEditTests`(17개, 모델 불필요): 검증·고정, 폴더 블렌드 거부, 배치 = undo 1단계 + 완전 복원, 이름으로 연쇄 참조, 실패 시 롤백, 게이팅(불투명도 드래그·busy), 라이브 마스크 소스 삭제 거부, `runJSON` 우회 차단, 도구가 실행 대신 제안, 대체(supersede), 이름 경고, 카드에서 이름 교정, 퍼센트 해석, `LayerRef` 축약형. `AssistantSessionTests`에 실모델 2개 추가(제안 → 승인 → undo 1단계, 사람이 편집하면 적용 거부). 전체 스위트 496개 중 495개 통과 — 실패 1개는 `SliderSnapTests`(SwiftUI `Slider` 안에서 `NSSlider`를 못 찾음, 어시스턴트와 무관).

### Stage 2b — `selection.*` (2026-10-11)

- **명령**: `selection.all` / `deselect` / `invert` / `rect` / `ellipse`(x, y, width, height + mode replace·add·subtract) / `expand` / `contract`(1–500px) / `feather`(1–250px). 전부 Select 메뉴의 세션 메서드(`selectAll`, `applySelection`, `expandSelection` …)를 그대로 호출 — 캔버스 클리핑·안티앨리어싱·페더 누적이 사람과 같다. 선택 영역은 문서 안에 있으므로 undo 대상이고 배치 한 단계에 들어간다.
- **검증**: 캔버스와 전혀 겹치지 않는 도형은 거부 — 클리핑되면 **명시적 빈 선택**이 되어 이후 편집이 "아무것도 안 건드림"이 된다(1.3). invert/expand/contract/feather는 현재 선택이 있거나 같은 제안 안에 앞서 선택을 만든 편집이 있어야 한다(`EditCommand.needsSelection`/`createsSelection`, `propose(selectionPending:)`). 게이팅에 `lassoDraft`(올가미·마키를 그리는 중) 추가.
- **도구 `editSelection`** — 측정으로 정해진 형태(한국어 요청, 400×200 캔버스):
  1. **좌표는 앱이 계산한다**: 모델은 "가운데 100×100"을 (100,100)/(200,100)/(50,100)에 놓았다(0/3). `region` enum(topHalf/bottomHalf/leftHalf/rightHalf/center/custom)을 두고 도구가 캔버스 크기로 계산 → 4/4. center에 한 변만 오면 정사각형(모델이 height를 자주 빠뜨림).
  2. **옵셔널 `mode` 칸 폐기, 빼기는 모델에게 주지 않는다**: 옵셔널 mode가 있으면 그냥 "선택해줘"에도 subtract를 채웠고(2/15), `subtractRectangle` 동작을 주면 "아래쪽 절반"에 그걸 골랐다(2/3). 빼기는 드물고 반대 결과를 내므로 실행기만 지원. 추가는 `addRectangle`/`addEllipse` 동작으로.
  3. **enum 순서·설명이 결과를 흔든다**: `leftHalf`가 첫 항목일 때 "위쪽 절반"에 3/3 `leftHalf`. "ellipse = oval or circle"만 쓰면 "사각형 추가"가 3/3 타원으로. 사각형·타원을 균형 있게 설명하자 최종 18/20. **3회 표본은 변동이 크다 — 문구를 바꾸면 반드시 다시 잴 것.**
- **최종 측정**: 전체 선택 2/3·해제 2/3(실패는 무응답)·반전 3/3·왼/아래/위(타원) 절반 3/3–4/4·가운데 4/4·확장 3/3·페더 3/3·원 추가 4/4, **사각형 추가 2/4**(나머지는 타원으로 — 카드에 "타원 선택에 추가"로 보임). 레이어 회귀 3/3.
- **테스트** `SelectionCommandTests`(6개): 캔버스 밖·크기 0 거부, 선택 필요 조건(앞선 제안 포함), 배치 = undo 1단계 + 복원, 추가 결합·중복 해제, 영역 → 좌표 계산, 도구가 빼기를 내지 않음.

### Stage 2c — `mask.*` (2026-10-11)

- **명령**: `mask.add`(reveal: 흰/검), `mask.addFromSelection`(shows: selection/outside — 같은 단계에서 선택 해제), `mask.setEnabled`, `mask.delete`, `mask.clipToBelow`, `mask.releaseClipping`. 레이어 패널의 세션 메서드(`addLayerMask`, `addMask`, `toggleLayerMask`, `deleteLayerMask`, `toggleClippingMask`, `removeLiveMask`)를 그대로 호출. 대화상자 없음.
- **이 앱의 반대 기본값**: `addMask(revealing: true)`(레이어 패널 버튼의 기본)는 선택이 있으면 **선택 영역을 숨긴다**(Photoshop은 드러냄). 그래서 명령·도구·카드 모두 마스크 색이 아니라 **무엇이 보이는지**로 이름 붙인다(`shows: .selection` → `revealing: false`). `MaskCommandTests`가 마스크 픽셀로 이를 검증한다.
- **검증**: 이미 마스크가 있으면 추가 거부, 없으면 켜기/끄기/삭제 거부, 클리핑은 `canToggleClippingMask`(폴더 아님, 같은 폴더 바로 아래에 폴더 아닌 레이어). 클리핑 해제 시 같은 기준으로 위에 클리핑된 레이어 수를 카드에 표시. 같은 레이어의 마스크 생성 두 건은 대체(`supersedingKey` "mask.create") — 모델이 두 번 넣은 적이 있고, 그대로면 두 번째가 실패해 배치 전체가 롤백된다.
- **도구 `editMask`**(4번째 도구 — 권장 3–5개 안): `layer`는 **필수** 칸. 동작 이름에서 **"hide"를 뺐다** — `addHideAll`이 있을 때 "Photo 숨겨줘"가 레이어 숨기기 대신 숨김 마스크로 갔다(0/3 → 이름 변경 후 3/3). 동작별로 한 줄씩 의미를 적은 guide가 끄기/삭제 혼동(삭제 → 끄기 2/3)을 고쳤다.
- **측정은 실제 경로로**: 레이어가 여럿이면 모델이 편집 전에 renderCanvas를 먼저 부르고, 첫 턴은 "이미지를 기다림"으로 끝난다. 실제 앱은 `AssistantSession`이 이미지를 붙여 재질문하므로 거기서 제안이 나온다. **`LanguageModelSession`을 직접 돌리는 측정은 이 경로를 빠뜨려 과소평가한다 — `AssistantSession.send` + `proposal`로 잴 것.**
- **최종 측정**(`AssistantSession.send`, 레이어 3개 + 선택 있음): 마스크 추가 2/3·선택으로 보이게 3/3·끄기 3/3·삭제 3/3·클리핑 3/3, 레이어 숨기기·불투명도 3/3, 가운데 선택 3/3 — 23/27. **"전부 가리는 마스크"는 0/3**(일관되게 "전부 보임"을 고름, 카드에 "(전부 보임)"으로 보임).
- **테스트** `MaskCommandTests`(7개).

### 2단계 남은 일

- `adjustment.*` 패밀리. (`selection.*`는 2b, `mask.*`는 2c로 완료. Select Subject(`ObjectSelection`, 비동기 ML)는 아직.)
- ~~승인 카드에서 이름을 바로 고칠 수 있게~~ → 완료(2026-10-11). 테스트: `correctingANameOnTheCardCarriesThroughTheProposal`, `aNameCorrectionThatWouldBeInvalidIsRefused`.
- 도구 enum이 커질수록 정확도가 변할 수 있으니 패밀리를 추가할 때마다 위 측정을 다시 할 것.

## 2.15 다음 세션에서 이어가기 (2026-10-12 기준)

### 현재 상태

- 브랜치 `ai-assistant`(포크 `origin` = `mechurisr/Compositor`; `upstream` = `robbietilton/Compositor`에는 push 금지).
- 커밋 순서: `a7f8918` 캔버스 비전·한국어 → `d299450` 탭별 어시스턴트 → `9ef270c` 2a `layer.*` → `b83fbbd` 카드에서 이름 교정 → `d3ccd88` 2b `selection.*` → 2c `mask.*`(이 섹션과 함께 커밋).
- `origin`에는 `9ef270c`까지 push됨. 그 뒤 커밋은 로컬에만 있다.
- **2c(`mask.*`)는 테스트·실모델 측정은 끝났지만 앱에서 사람이 직접 확인하기 전**이다. 이어서 시작하면 먼저 확인할 것: 선택 → "선택 영역만 보이도록 Layer 1에 마스크 만들어줘" → 적용 후 선택 부분만 남는지 / 마스크 끄기·켜기·삭제 / 위 레이어를 아래에 클리핑.
- 모델용 도구 4개: `inspectDocument`, `editLayer`, `editSelection`, `editMask`. Apple 권장 3–5개의 상한에 가깝다 — 5번째(조정 레이어)가 마지막 여유분.

### 다음 단계: 2d `adjustment.*` — 미리 확인해 둔 것

- `EditorSession.addAdjustment(_:)`(`Document/LayerAdjustment.swift:184`)는 레이어를 만든 뒤 편집 가능한 종류면 **`adjustmentEditingID = layer.id`로 편집기를 연다**. 편집기는 `UI/LayersPanel.swift:67`의 `.task(id: adjustmentEditingID)`가 **비동기로** 연다 → AI 경로에서는 `addAdjustment` 직후 같은 메인 액터 턴 안에서 `adjustmentEditingID`가 새 레이어 id면 `nil`로 되돌려 편집기가 열리지 않게 한다. 안 하면 적용 후 편집기가 열린 채 남고 `layerEditBlocker`가 이후 편집을 막는다.
- `updateAdjustment(_:value:)`(`:206`)는 `beginEdit`/`endEdit`이 없다(라이브 프리뷰용) — 배치의 바깥 `beginEdit` 안에서만 부를 것. `value.isValid`가 아니면 조용히 무시하므로 적용 후 확인 필요.
- 값 검증은 각 설정 구조체의 `isValid`/범위 상수를 재사용(1.2): `ExposureSettings.exposureRange` 등, `HueSaturationSettings`(범위별 hue/saturation/lightness).
- 조정 레이어는 활성 레이어 바로 위(활성 폴더 안)에 생긴다. 모델에게는 종류 + 대표 값 1–2개만 주는 것을 권장(예: Exposure 스톱, Hue/Saturation의 saturation/lightness) — 필드가 많으면 엉뚱한 칸을 채운다(아래 교훈 2).

### 온디바이스 모델과 일할 때의 교훈 (2.13–2.14 실측 요약)

1. 도구 결과 속 이미지는 모델이 못 본다 → `CanvasImageMailbox`로 재질문.
2. 옵셔널 칸이 많으면 엉뚱한 칸을 채운다(blendMode를 name 칸에, 선택 mode를 subtract로) → 값은 칸 하나(`value`)로 받거나, 의도를 **동작 이름**에 담는다.
3. enum 이름·순서·설명 한 줄이 결과를 크게 바꾼다(`leftHalf`가 첫 항목이면 "위쪽"도 leftHalf, 마스크에 "hide"가 있으면 "숨겨줘"가 마스크로). 도구 간 단어 충돌을 피할 것.
4. 계산(좌표, 중앙)은 모델에게 맡기지 말고 도구가 한다.
5. 지시문에 언어 이름을 쓰지 않는다(한국어 질문에서 도구 호출이 멈춤). 번역은 별도 세션.
6. 모델은 도구 에러·경고를 받아도 재시도하지 않는다 → 처음부터 맞게 부르게 하고, 나머지는 승인 카드가 잡는다.
7. 조사 붙은 한국어 이름은 번역·변형된다 → 카드 경고 + 카드에서 이름 교정.

### 측정 절차

- `RunCodeSnippet`(소스 컨텍스트 `Compositor/Compositor/Assistant/AssistantSession.swift`)으로 요청 × 3–4회. **실행 중인 앱이 있으면 스니펫이 SwiftUI 창 레이아웃에서 크래시하므로 먼저 `StopProject`.** 크래시 스택이 `RootWindowLayoutComputer`면 하네스 문제 — 재실행.
- 실제 경로로 잴 것: `AssistantSession(editorSession:)` → `await send(q)` → `proposal?.edits`. `LanguageModelSession`을 직접 돌리면 이미지 재질문 단계가 빠져 과소평가된다.
- 판정은 엄격하게(모드·좌표 포함 정확 일치). 3회 표본은 변동이 크니 문구를 바꾼 뒤엔 반드시 다시 잰다.
- 모델 없이 도는 테스트: `EditCommandEditTests`, `SelectionCommandTests`, `MaskCommandTests`, `EditCommandTests`, `EditCommandCatalogTests`. 실모델 테스트는 `AssistantSessionTests`(조건 불충족 시 조용히 통과 — 실행 시간으로 실제 실행 확인). 전체 스위트에서 `SliderSnapTests` 1개는 어시스턴트와 무관하게 실패한다(macOS 27의 SwiftUI `Slider`).

### 작업 방식 (사용자와 합의)

패밀리 하나씩: 구현 → 모델 없는 테스트 → 실모델 측정·조정 → 앱 실행 → **사용자가 앱에서 확인한 뒤 커밋**. push는 요청이 있을 때만.
