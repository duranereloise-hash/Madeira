# MadeiraTV — порт Madeira на tvOS 26 (Apple TV)

Порт запускает тот же стек **Wine (ARM64EC) + FEX-Emu (x86-64→ARM64) + DXMT (D3D11→Metal)**,
который собран в Madeira, но с интерфейсом, заточенным под гостиную: меню с фокус-навигацией
(Siri Remote / геймпад), постоянный геймпад как основной ввод и доставка игр по сети
(встроенный HTTP-сервер + deep link `madeira://`) — как это сделано в RetroArch для tvOS.

---

## 1. Что переиспользуется, а что пишется заново

| Слой | Статус | Комментарий |
|---|---|---|
| `libwineserver.a`, `libntdll_unix.a`, `libwin32u_unix.a`, `libdxmt_combined.a`, `libFEXCore*.a` и остальные железяки | **переиспользуются** | Это армированные `.a`, не зависят от SDK-таргета. Главная работа порта — **пересобрать их под `appletvos`** (см. §7) |
| `Winios.m/h` (winios.drv: окна, композитор, очередь ввода) | **переиспользуются** | Код UIKit-совместим; на tvOS всё необходимое (`UIWindow`, `CALayer`, `CAMetalLayer`, `UIApplication`) доступно |
| `IOSDisplayShim.m`, `FEXBridge.mm`, `WineServerBridge.m`, `WineProcessBridge.m`, `JITAllocator.c`, `PrefixExtractor.c`, `wine_stubs.c`, `LogStore/LogPattern/LogTail`, `FPSOverlay` | **переиспользуются** | Входят в новый таргет как есть |
| `ContentView.swift` (iPhone-UI) | **НЕ используется** | Заменяется tvOS-меню (§3) |
| `StikJITHelper.swift` | **НЕ используется** | Логика «пул через BRK + пиннинг» вынесена в `TVJIT.swift` (тот же протокол `BRK #0xf00d`, но без UI StikDebug) |
| Мост «геймпад → Wine» | **пишется заново** | `GamepadManager.swift` (§5) |
| Хост загрузки игр | **пишется заново** | `UploadHost.swift` + `URLHandler.swift` (§6) |

---

## 2. Критичное ограничение: JIT на tvOS

Весь стек работает только с JIT для x86-64 гостя. На заблокированном устройстве JIT-память
даёт **отладчик (CS_DEBUGGED)**, как и на iOS:

- **Режим A — отладчик (рекомендуется, это путь iOS):** приложение запускается из
  StikDebug/StikJIT (на tvOS — `StikDebug tvOS`), отладчик ставит `CS_DEBUGGED` и
  обслуживает `BRK #0xf00d`. Приложение само аллоцирует пул через `jit26_prepare_region`,
  детачится после загрузки PE (повторяет `runWineFullSequence`).
- **Режим B — bruteforce (fallback):** `TVJIT` пытается получить `MAP_JIT` во все
  возможные стороны (это физически невозможно на заблокированной tvOS с App Store-подписью)
  и сообщает точную причину отказа. Режим нужен, чтобы «нет JIT» было диагностируемым,
  а не молчаливым чёрным экраном.

Индикатор JIT (нет/есть/пул-готов) выводится в меню (§3) и в `TVRunner` перед запуском.
Приложение **не стартует Wine без пула** — повторяет защиту ml596 из `ContentView.swift`.

---

## 3. Меню — адаптация под tvOS 26

### 3.1 Фокус вместо тапов
iOS-экран целиком завязан на тапы, слайдеры, клавиатуру и ориентацию — на Apple TV этого
нет. Меню строится заново на **SwiftUI focus-модели**:

- `@FocusState` + `.focused($f)` + `.focusable()` — вся навигация.
- Грид карточек игр — «Game Center-style»: горизонтальный `ScrollView` + `LazyHGrid`,
  одна строка = один `focusSection`; `@FocusState` на `ScrollViewReader` скроллит к
  сфокусированной карточке (`.onChange(of: focus)` + `scrollTo`).
- Секции: **Now Playing** (последний запуск, крупная карточка, `prefersDefaultFocus`),
  **Библиотека** (все игры), **Сервисы** (хост загрузки), **Настройки/Диагностика** (лог,
  JIT-статус).
- Отмена/меню: кнопка **Menu** на пульте/геймпаде закрывает экран `TVRunner` и возвращает
  фокус в библиотеку.

### 3.2 tvOS-специфика, учтённая в коде
- Нет `UIStatusBar`, нет `verticalSizeClass`-переключения — меню единое, в landscape.
- `.cardBackground`/`.buttonStyle(.card)` там, где уместно; акцент — на фокус-подсветке
  (масштаб + «параллакс» карточки), чтобы меню читалось с дивана.
- `UIScreen`/`UIApplication`-вызовы (idle-timer, FPS) в общих файлах обёрнуты в
  `#if os(iOS)`; tvOS-таргет их не видит.

---

## 4. Библиотека игр

- Каталог `Documents/Games/` — единственный источник игр.
- При старте сканируется рекурсивно; exe-файлы (`*.exe`) = запускаемые игры; рядом лежит
  `cover.png/jpg` для карточки (если нет — генерируется инициал имени).
- Игра хранится как **Windows-путь** (`C:\Games\Thumper\THUMPER_win10.exe`), который
  `WineProcessBridge` умеет запускать напрямую; в `TVRunner.launch` выставляются
  `MADEIRA_EXE` / `MADEIRA_ARGS` / `MADEIRA_USE_ARM64EC=1` (для полных путей он и так
  выбирается автоматически).
- Избранное/порядок — `UserDefaults` (лёгкое, без лишнего ввода).

---

## 5. Геймпад (`GamepadManager`)

Apple TV не имеет экранных кнопок — геймпад (Siri Remote, DualShock/DualSense, Xbox) это
**основной** ввод. Используется `GameController.framework`:

- `GCController.controllers()` + уведомления `GCControllerDidConnect`/`DidDisconnect`;
- берём `extendedGamepad`, читаем по `valueChangedHandler` (аналоговые стики, бамперы,
  триггеры, D-pad, кнопки);
- маппинг в Wine-ввод через существующий мост `winios_*`:
  - **левый стик/D-pad** → стрелки (`winios_post_key`, VK 0x25–0x28), мёртвая зона 0.25 —
    совместимо с играми, понимающими только клавиатуру;
  - **правый стик** → относительное движение мыши (`winios_pointer` с `F_MOVE`
    и дельтой, как mouse-look в `ContentView`), нужно для шутеров;
  - **геймпад-кнопки** → WASD/Enter/Esc/пробел (A=Enter, B=Esc, X=пробел, Y=Tab,
    бамперы=Shift/Ctrl, Menu=Esc) — «клавиатурный» слой;
  - **правый триггер** → левая кнопка мыши (L-триггер — правая), «мышиный» слой.
- **Честная оговорка в коде и доке:** полноценного **XInput в Wine пока нет** — в
  `ContentView.swift` XInput-вкладка явно помечена «not wired». Маппинг в клавиши/мышь —
  рабочий MVP, который заводит любой геймпад на любую игру; поверх него потом ляжет
  настоящий XInput-мост (Wine HID + `windows.gaming.input.dll`), и `GamepadManager`
  достаточно будет дополнить, не переделывая.

---

## 6. Хост загрузки игр + deep link (RetroArch-стиль)

RetroArch на tvOS раздаёт контент встроенным HTTP-сервером и запускает его из
`retroarch/downloads`. Повторяем ровно это:

- **Встроенный HTTP-сервер** (`Network.framework`, без внешних зависимостей) слушает
  `0.0.0.0:8080`:
  - `GET /` — HTML-страница загрузки (drag&drop / кнопка выбора .exe);
  - `POST /upload?name=Thumper.exe` — multipart или raw body сохраняется в
    `Documents/Games/`;
  - `GET /games` — JSON-список уже загруженного (видно с телефона/ПК, что уже есть).
  - Порт берётся из `UserDefaults` (`madeira.hostPort`, по умолчанию 8080) и показывается
    на экране «Сервисы» — адрес вида `http://<ip Apple TV>:8080`.
- **Deep link `madeira://`:** `CFBundleURLTypes` в Info.plist; `onOpenURL` парсит
  `madeira://launch/<name>` — находит игру в библиотеке и запускает. Это позволяет
  внешним приложениям (менеджерам ромов/библиотек) открывать игру одним тапом, как
  RetroArch с `retroarch://`.

---

## 7. Сборка: новый таргет `appletvos`

1. **Железо (один раз, на Mac):** пересобрать `build/*/build.sh` с `SDK=appletvos`
   (флаги в скриптах вынесены в переменные; `xcodebuild` с `-sdk appletvos` + `--target arm64`
   для meson-частей). Это самый долгий шаг порта и единственный, где нужен Mac/Xcode.
2. **Новый таргет** `MadeiraTV` в `Madeira.xcodeproj` — готовый сниппет pbxproj
   ниже + полное описание в `app/MadeiraTV/BUILDING.md`.
   - `SUPPORTED_PLATFORMS = appletvos appletvsimulator`, `SDKROOT = appletvos`,
     `TARGETED_DEVICE_FAMILY = 3`, `IPHONEOS_DEPLOYMENT_TARGET` → `TVOS_DEPLOYMENT_TARGET = 18.0` (или 26.0),
     `PRODUCT_BUNDLE_IDENTIFIER = com.willfaust.madeira-tv`;
   - Sources: общие файлы + `MadeiraTV/*.swift`; Resources: все папки-DLL, prefix-template,
     cacert — как в iOS-таргете; Frameworks: те же `.a`/`.tbd` + **`GameController.framework`**;
   - Entitlements/Info.plist: копия iOS + `CFBundleURLTypes` (`madeira`), без
     `UIRequiredDeviceCapabilities=arm64` (на tvOS не применимо; достаточно arm64 по факту).
3. **Подпись/установка:** тот же путь, что iOS — StikDebug (сейчас доступен и для tvOS),
   бесплатный Apple ID, переустановка раз в 7 дней. JIT — как в §2.

---

## 8. Ограничения и риски (честно)

- **JIT — обязателен.** Без отладчика (режим A) стек не выполняется. На «чистой» tvOS
  без StikDebug приложение честно показывает «JIT required» и не запускает Wine.
- **Производительность:** Apple TV (A15/A17 и новее) — тот же класс CPU, что iPhone 13 Pro,
  на котором гоняются Thumper/ULTRAKILL; ожидаемо «как на iOS», но жара/троттлинг в
  коробке сильнее.
- **XInput:** геймпад работает через клавиатурно-мышиный слой; игры, требующие именно
  XInput-контроллера, лягут после реализации XInput-моста.
- **Файлы:** из-за песочницы tvOS игры доставляются только через наш хост/URL (или
  devicectl при разработке), как в RetroArch.
- **Дисплей:** 4:3/16:9 игра аспект-фитится в 16:9; letterbox настраивается в
  `TVRunner` (по умолчанию aspect-fit, как в iOS).

---

## 9. Структура новых файлов

```
app/MadeiraTV/
  MadeiraTVApp.swift      @main, WindowGroup, onOpenURL, GamepadManager.shared.start()
  Models.swift            GameEntry, GameLibrary (сканирование Documents/Games), JITState
  LibraryView.swift       tvOS-меню: фокус, грид, секции, сервисы/настройки
  TVRunner.swift          экран запущенной игры: пул → wineserver → wine, выход по Menu
  TVJIT.swift             пул BRK#0xf00d (портированная логика StikJITHelper без UIKit)
  GamepadManager.swift    GCController → winios_post_key / winios_pointer
  UploadHost.swift        HTTP-сервер загрузки (Network.framework)
  URLHandler.swift        madeira://launch/<name>
  Info.plist              tvOS: madeira URL scheme, landscape
  MadeiraTV.entitlements  allow-jit + increased-memory (как iOS)
  BUILDING.md             сниппет pbxproj-таргета appletvos + шаги пересборки библиотек
```

Порядок запуска у `TVRunner` повторяет `runWineFullSequence` из iOS:
`jit_check_debugged() → TVJIT.allocatePool() → wineserver_start(prefix) →
wine_process_start(prefix) → ожидание показов → детач отладчика`.
```