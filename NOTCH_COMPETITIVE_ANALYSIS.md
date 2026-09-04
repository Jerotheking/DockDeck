# DockDeck — Análisis competitivo: notch apps para macOS

**Fecha:** 2026-09-04 · **Método:** fuentes primarias cuando existen (GitHub, docs, medición propia en la máquina de Jero) + comparativas independientes. Cada afirmación lleva su etiqueta de epistemicidad.

**Contexto:** el usuario (Jero) reporta que la geometría dock-adyacente no le genera uso (*"no me veo usándolo"*) y propone el notch como ancla. Su MacBook **sí tiene notch real** (`safeAreaInsets.top = 38 pt` en la pantalla integrada, `[VERIFICADO]` en vivo); su LG principal (donde vive el Dock) no lo tiene. Cualquier decisión debe ser por-pantalla.

---

## 1. El mapa del género

| App | Precio | RAM idle | Enfoque | Fuente |
|---|---|---|---|---|
| **NotchNook** (Lo.Cafe) | $30 una vez | ~110 MB | El estándar de pulido: música, file tray, AirDrop, calendario, widgets | comparativa Brow `[INFERIDO]`, sitio oficial `[VERIFICADO]` (poco detalle técnico) |
| **boring.notch** (The Bored Team) | Gratis, OSS (MIT) | ~60 MB | Música primero (visualizador, controles), file shelf, calendario, HUD replacement | GitHub `[VERIFICADO]` |
| **NotchDrop** (Lakr Aream) | Gratis, OSS | ~40 MB | Una sola cosa: staging temporal de archivos + AirDrop | GitHub `[VERIFICADO]` |
| **Brow** | Gratis (beta) | ~50 MB | 7 módulos: screenshots+OCR, pomodoro, stats, drop zone, música, gestor de menu bar, displays | comparativa ( biased: es su app) `[INFERIDO]` |
| **MediaMate** | $5 | ~70 MB | Música + AirDrop, minimal | comparativa `[INFERIDO]` |
| **Alcove** | $5 | ~80 MB | Imitación del Dynamic Island del iPhone | comparativa `[INFERIDO]` |
| **Notchify** | Freemium ($3/mo) | ~90 MB | Música, clima, calendario | comparativa `[INFERIDO]` |
| **TopNotch** | Gratis | ~10 MB | Lo contrario: **esconde** el notch con wallpaper negro | comparativa `[VERIFICADO]` |

Datos de precio/RAM: comparativa independiente de Brow (mayo 2026), que declara su propio bias. Nadie publica RAM oficial. `[INFERIDO]`

---

## 2. La gramática del género (lo que todos los sobrevivientes comparten)

Extraída del comportamiento documentado de los tres referentes:

1. **Anclaje centrado en el notch, silueta idéntica al colapsar.** La ventana colapsada *es* el notch: misma forma, mismo negro, quelques píxeles más. El usuario no "abre una app" — el notch *se estira*.
2. **Dos gatillos: hover con delay corto + arrastre.** El hover expande (boring.notch: "hover over the notch to see it expand"); el drag-and-drop funciona **sobre el estado colapsado** — el notch mismo es el drop target (NotchDrop). Nunca hay que abrir nada para soltar un archivo.
3. **El morph es EL producto.** NotchNook lo define: "album art that morphs as it expands" — una sola pieza de material deformándose entre estados, no dos vistas en crossfade. Es exactamente el principio 1 de nuestro design doc ("el vidrio es uno") y la API `NSGlassEffectContainerView` de macOS 26. **Construimos ese músculo en WS-2 sin saber para qué servidoría aquí.**
4. **Tres familias de contenido:** media (música — el terreno de todos), *staging* de archivos + AirDrop (la utilidad que todos mantienen), y glances de sistema (batería/carga, calendario).
5. **El colapsado no está muerto.** Los sobrevivientes muestran algo en reposo: arte del álbum, cuenta de archivos, countdown del timer.
6. **Mono-display.** El notch solo existe en la pantalla integrada del MacBook; todas estas apps viven ahí y no tienen respuesta para un setup con monitor externo.

---

## 3. La paradoja del notch (por qué la mayoría muere)

> *"Most people install a notch app, use it for two weeks, then stop opening it. The notch is small, you have to hover or scroll to expand it, and the friction of 'remember the notch is there' is real."* — Brow, comparativa 2026 `[VERIFICADO]` como hallazgo del género (coincide con el sentimiento en r/macapps: "pricing ridiculous", bugs, desgaste `[INFERIDO]`).

**Los que sobreviven a 30 días comparten un rasgo: hicieron el notch pasivo, no activo.**

- El drop zone es *ambiental*: solo interactúas cuando ya traes un archivo en la mano.
- La música *aparece sola* cuando hay reproducción.
- El timer/stats se actualizan sin que nadie los abra.

**Implicación de diseño para DockDeck:** si el modo notch requiere "acordarse de abrirlo", muere como murió la mitad del género. El estado colapsado debe valer por sí mismo (glance vivo) y el gatillo principal debe ser el gesto que el usuario ya estaba haciendo (soltar un archivo), no un ritual nuevo.

---

## 4. Dónde está el hueco (nuestras aperturas concretas)

1. **Nadie tiene un estante persistente y organizado.** NotchDrop — el mejor del género en archivos — *expira todo a 24 horas* ("Automatically save files for 1 day"), sin organización, sin notas, sin portapapeles, sin búsqueda. boring.notch construyó su shelf sobre el código de NotchDrop (acknowledged en su README) → mismos límites. **Nuestro `ShelfStore` (persistencia, pinning, notas, clipboard history, búsqueda, rename/compress/reveal) es categóricamente más profundo que cualquier file-tray del género.** `[VERIFICADO]` en sus READMEs/behavior docs.
2. **Fragmentación de setup.** El usuario con MacBook + monitor necesita hoy: una notch app en la MacBook y *algo distinto* cerca del Dock en el monitor. **Nadie ofrece un solo producto con ancla por-pantalla.** Nuestro código ya tiene la mitad: motores de geometry, springs, glass y tracking probados.
3. **El pricing deja un espacio:** $30 one-time arriba, OSS gratuito abajo, suscripciones resentidas. Un producto gratuito/nuestro con la función más mantenida del género (archivos) compite sin pelear en música.
4. **Música: NO entrar.** Es el terreno de todos (NotchNook, boring, MediaMate, Alcove, Notchify) y requiere interceptar Now Playing (API privada / `MediaRemoteAdapter` — fragilidad conocida). Nuestro wedge es archivos/conocimiento, donde el género es más débil.

---

## 5. Anatomía técnica (lo que implicará construirlo)

Con la técnica de ventana confirmada por fuentes + nuestra base existente:

- **Detección del notch:** `NSScreen.safeAreaInsets.top > 0` identifica la pantalla con notch (38 pt en la de Jero `[VERIFICADO]`); la zona del notch queda entre `auxiliaryTopLeftArea.maxX` y `auxiliaryTopRightArea.minX` (API pública de AppKit). Sin hacks.
- **Ventana colapsada:** panel flotante con la silueta del notch (+~4 pt de margen de clic), en un nivel que conviva con la menu bar real — **jamás cubrir la cámara ni ítems reales de la menu bar** (los aux areas existen justo para eso).
- **Expandir:** la misma pieza de vidrio crece hacia abajo (morph, `NSGlassEffectContainerView` si macOS 26; fallback WS-2 ya construido). El contenido abierto = nuestra UI de shelf existente, montada *en el frame 1* (lección B3).
- **Fullscreen:** cuando la app frontal está fullscreen en esa pantalla, la menu bar desaparece → anclar a la orilla física superior con comportamiento reducido (el patrón que NotchNook sigue; los hacks de Panaitiu con Frida son para ventanas ajenas, no aplican a un panel propio).
- **Sin notch (LG, o Macs viejos):** fallback automático al modo Dock actual. **Settings: "Anclaje por pantalla"** (Notch / Dock / Off por display).
- **Batería/CPU:** cero timers en reposo (lección WS-0 y la queja de batería en reseñas de NotchBox); eventos de drag/hover solamente.

---

## 6. Decisiones de producto que este análisis propone

| # | Decisión | Racional |
|---|---|---|
| P1 | **Modo notch = estante persistente**, no staging efímero | Es el hueco del género: NotchDrop expira en 24 h; nadie organiza |
| P2 | **El colapsado es un glance vivo** (conteo de ítems, último clipboard) + drop target en silueta | La paradoja del notch: pasivo o muere |
| P3 | **Sin música ni HUD** | Terreno saturado + fragilidad de API privada; nuestro wedge es otro |
| P4 | **Un store, ancla por pantalla** (notch en MacBook, shelves de Dock en el LG) | Resuelve el setup real de Jero; posicionamiento sin competencia |
| P5 | **El morph es el estándar de calidad de entrada** | Es lo que NotchNook cobra $30 por cobrar; ya tenemos WS-2 |
| P6 | DockDeck sigue siendo una sola app con dos anclas — no un fork "notch app" | Identidad: *el estante que sigue a tu atención* |

---

## 7. Veredicto

**Construir el modo notch vale la pena — con el wedge correcto.** El género validó el ancla (todos cobran o existen por ella) y dejó abierta exactamente la casilla que ya sabemos construir mejor que nadie: **el estante persistente de archivos/notas/clipboard**. La paradoja del notch dicta el diseño: valor pasivo en reposo, drop sin abrir, morph como firma visual. Y para Jero específicamente: su MacBook gana un estante donde su mirada ya vive, sin renunciar a los shelves del Dock en el LG.

*Próximo artefacto natural: el design brief del modo notch (estados, medidas, edge cases) heredando la estructura de `DESIGN_THINKING.md`, y luego el code spike del ancla.*
