# CLAUDE.md — Compositor

macOS용 Photoshop 대체 이미지 편집기 (Swift / SwiftUI / AppKit / Core Graphics / Core Image / Metal + C 픽셀 커널).
저장소: `robbietilton/Compositor` · 소스 약 40k 줄 · 앱 코드 `Compositor/`, 테스트 `CompositorTests/`(Swift Testing).

이 문서는 두 부분이다.

1. **[1부] 코드베이스 분석** — 문서·레이어 모델, 조정/필터 적용 경로, 선택 영역·마스크 표현, 되돌리기 구조.
2. **[2부] AI 어시스턴트 설계 계획** — JSON 명령으로 호출 가능한 `EditCommand` 계층. **계획 단계이며 아직 구현된 코드가 없다.**

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
  AssistantSession.swift      # @Observable 대화 상태 + 턴 교대
  AssistantClient.swift       # Anthropic Messages API 전송 (tool use)
Compositor/UI/
  AssistantPanel.swift        # 채팅 사이드바
CompositorTests/
  EditCommandTests.swift
  EditCommandCatalogTests.swift
  AssistantGatingTests.swift
```

`EditorSession`을 더 키우지 않기 위해 별도 폴더로 둔다. `EditorSession`에 필요한 변경은 **`DocumentHistory.revision`을 읽기 전용으로 노출하는 것 하나뿐**(현재 `private`)이다 — 2.7의 낙관적 동시성에 쓴다.

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

- `ProjectTab`(`ProjectWorkspace.swift:6`)에 `session`/`controller` 옆에 `assistant: AssistantSession`을 추가 — **탭마다 독립 대화**. 기존 탭별 소유 구조와 일치한다.
- 패널은 `ProjectWorkspaceView` / `ContentView.swift`에 사이드바로.
- API 키는 Keychain. 네트워크 엔타이틀먼트는 **이미 켜져 있다**(`Config/Compositor.entitlements`).

## 2.10 테스트 계획

기존 방식 그대로, UI 없이 가능하다.

- `EditorSession()` + `createDocument` → JSON 명령 실행 → `document` 상태 검증. 배치마다 `session.history.undoCount == 1`이고 `session.undo()`가 완전히 복원하는지.
- 모든 명령의 JSON 왕복 디코드. 카탈로그 커버리지.
- **게이팅 테스트**: `session.textDraft` / `transformEdit` / `isProjectBusy`를 세팅해두고, 명령이 문서를 바꾸는 대신 올바른 에러 코드로 거부하는지.

## 2.11 단계별 진행

| 단계 | 범위 |
|---|---|
| 1 | `query.*` 전용(변경 없음) + 카탈로그 + 패널. digest와 프롬프트의 타당성을 먼저 증명한다. |
| 2 | `layer.*`, `selection.*`, `mask.*`, `adjustment.*` + 원자적 배치 + 승인 UI. |
| 3 | `filter.*`(비동기 모달 구동), `effects.*`, `transform.*`. |
| 4 | `pixels.*`, 브러시, 내보내기. |

## 2.12 위험과 미결정 사항

- **브러시 스트로크**를 명령으로 노출하는 건 표면이 크다(`BrushStroke.swift` 902줄, 비동기·상태 유지). 4단계로 미룬다.
- **Camera Raw**는 하위 섹션이 10개쯤 된다. 슬라이더별 명령이 아니라 `cameraRaw` 설정 blob 하나로 노출한다.
- **토큰 비용**: digest 크기, 썸네일, 캔버스 렌더. 매 턴 전체 캔버스를 보내지 않는다.
- **오프라인 앱에 네트워크가 들어온다**는 점 자체를 사용자에게 명시해야 한다(API 키·전송 내용).
- 파괴적 필터는 레이어 픽셀을 교체한다 — `DocumentHistory`의 256 MiB 보존 한계(`DocumentHistory.swift:28`)에 AI의 연속 작업이 빨리 닿을 수 있다. 배치를 원자적으로 묶는 것이 여기서도 도움이 된다.
