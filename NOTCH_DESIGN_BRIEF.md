# DockDeck — Design Brief: Modo Notch

**Fecha:** 2026-09-04 · **Base:** `NOTCH_COMPETITIVE_ANALYSIS.md` + `NOTCH_DEEP_DIVE.md` (código fuente de la competencia leído) + `DESIGN_THINKING.md` (principios). Números calibrados con la máquina real de Jero `[VERIFICADO]`.

---

## 1. Definición de producto

**DockDeck en modo notch:** *el estante persistente que cuelga del notch de tu MacBook* — con la gramática visual del Dynamic Island, la profundidad de un estante de verdad, y sin las dos debilidades del género: **no expira** y **no depende de música**.

- **Wedge (P1 del análisis):** estante organizado y permanente — archivos, notas, clipboard, links — con búsqueda, pinning y acciones reales. NotchDrop borra todo a las 24 h; nadie organiza.
- **Identidad (P6):** una sola app, dos anclas. El notch en la MacBook, los shelves del Dock en los monitores externos. Un store, dos lugares.
- **Lo que NO es (P3):** reproductor de música, reemplazo de HUD, espejo de cámara. Terreno saturado y frágil del género.

**Historia central:** *Arrastro un archivo hacia arriba, y el notch lo recibe — como siempre supuse que debía funcionar. Cuando quiero algo de ayer, ahí sigue. Cuando cambio al monitor grande, el estante está junto a mi Dock.*

---

## 2. Estados y geometría (con números reales de la MacBook de Jero)

La pantalla integrada mide 1800×1169; notch **220×38 pt**; menu bar 38 pt; aux areas 790+790 `[VERIFICADO]`. Todas las constantes se derivan de la pantalla en runtime — nada de esto va hardcodeado.

| Estado | Geometría (anchura × profundidad visible) | Silueta |
|---|---|---|
| **closed** | notch real **+4 pt de margen de clic** por lado (224×38). La ventana pinta la silueta; fuera de ella es transparente | La del notch físico: curvas cónicas arriba (r≈6), flare abajo (r≈14), exactamente `NotchShape` |
| **peek** (sneak) | 2 tamaños: **256×52** (clipboard/archivo entrante) y **320×52** (glance de estado) | El notch se estira en anchura y baja ~14 pt, luego vuelve |
| **open** | **640 × 420** por defecto (slider 320–560 de profundidad). Ventana = contenido + 20 pt de padding de sombra abajo, contenido anclado al tope | Esquinas abiertas (r≈18), una pieza que crece desde la silueta cerrada |

- **Anclaje:** centrado en el notch, tope pegado al borde físico de la pantalla (`screen.maxY`), nunca dentro del área de la cámara.
- **Regla de oro del colapsado:** la silueta pintada debe cubrir el notch físico con precisión de píxel — ni negro sobrante sobre la menu bar (se vería como mugre) ni notch asomando (se vería roto). Calibración: `notchWidth = frame.width − auxL.width − auxR.width + 4` con inset −4 pintado, +4 de hit area.
- **Nivel de ventana:** `.mainMenu + 3` (encima de la menu bar, debajo de tudo lo crítico) `hasShadow=false` colapsado; sombra propia dibujada al abrir. `canBecomeKey = true` (la búsqueda se escribe ahí — la lección de boring.notch).

---

## 3. Gramática de activación (la unión del género, afinada)

| Gatillo | Comportamiento | Default |
|---|---|---|
| **Hover en la silueta** | abre tras 0.30 s (slider 0.1–1.0 s) | on |
| **Corredor de arrastre** | un drag con archivos en el pasteboard, a ≤48 pt del notch, abre **antes** de que llegues — soltar sobre el notch cerrado funciona | on, innegociable |
| **Click** | abre/cierra | on |
| **Esc / click afuera** | cierra (tras un delay de cortesía si hay drag activo — `preventNotchClose` de boring) | on |
| **Gesto drag-down** | cerrar arrastrando hacia abajo (sensibilidad ajustable, 200 px default) | on |
| **Sneak peeks** | eventos (item al clipboard, drop recibido, nota creada) estiran el notch 2.5 s y vuelven; si ya está abierto, solo un flash interior | on, configurable |
| **Hotkey global** | ⌥⇧N abre/cierra (reusa el dispatcher de hotkeys que ya tenemos) | on |

Cierre automático: pointer-out + 0.45 s (el mismo `collapseDelay` del modo Dock). Nunca se cierra con un share sheet activo.

---

## 4. Contenido: el estante dentro del notch

Reusa `ShelfViewController`/`ShelfStore` completos (persistencia, revisiones, límites por tipo). Específico del ancla:

1. **Abre donde estabas:** si el shelf tiene ítems, reabre en la pestaña del último uso (`openLastTabByDefault`); primer run → tour de 3 pasos.
2. **Tabs:** Archivos · Notas · Clipboard · Links (los cuatro `ItemKind` que ya existen).
3. **Acciones por ítem:** open, Quick Look, pin, copy, reveal in Finder, share/AirDrop (el glue de NotchDrop es un `NSSharingServicePicker` — 20 líneas, lo copiamos), rename, compress, markdown.
4. **Drop desde afuera:** file URL / URL / string — el mismo `registerForDraggedTypes` actual.
5. **Drag hacia afuera:** drag-out de un ítem hacia cualquier app (NSFilePromiseProvider en fase 2; v1 = drag de URL directo).
6. **Búsqueda inline** con el search field existente (exige `canBecomeKey = true`).
7. **Sin expiración.** Los staged de la competencia expiran; lo nuestro es un estante. (Si algún día pedimos "auto-limpiar", será opt-in por pestaña.)

---

## 5. Motion (el estándar de entrada del género)

- **Un material, un morph:** la silueta cerrada y el panel abierto son la misma pieza — animamos el path de la capa (radii cónicas incluidas) + frame en un solo spring; **prohibido** el swap de vistas. Es exactamente WS-2 ("el vidrio es uno") + `NSGlassEffectContainerView` cuando estemos en macOS 26.
- **Presets dedicados** (`SpringParameters.notchOpen/notchClose/notchPeek`): abrir ~0.32/0.85 (decidido, con 4% de overshoot), cerrar 0.24/0.92 (más rápido, casi sin rebote), peek 0.20/0.90. La competencia: NotchDrop 0.5 s bounce 0.25 (demasiado gelatina para un estante), boring más sobrio. Nos quedamos entre ambos, más rápido.
- **Inercia de contenido heredada** (WS-1): el contenido se inclina ≤2.5° con la velocidad del morph — gratis, ya construido.
- **Haptics** en abrir/cerrar/stage (la competencia lo tiene on por default; el usuario no lo ve, lo siente).
- **Corner radius scaling** al abrir (radii crecen con el panel — boring lo hace, vende el "un material").

---

## 6. Vida ambiental (la lección de la paradoja del notch)

El colapsado no puede estar muerto:

- **Glance de conteo:** con >0 ítems nuevos desde la última apertura, un punto de acento pulsante en la esquina derecha de la silueta (2×6 pt). Sutil, pasivo.
- **Sneak peeks reales:** al copiar algo (clipboard), el notch hace peek 2.5 s mostrando la primera línea. Al soltar un drop, confirma con un flash. Cadencia limitada (máx 1 peek cada 8 s) — la calma es la feature.
- **Nada de polling:** eventos del store + pasteboard-change + workspace, coalesced (el músculo WS-0).

---

## 7. Multi-display y fullscreen

- **Ancla por pantalla (P4):** notch mode en la pantalla con notch; en las demás, shelves de Dock (modo actual) u off — Settings por display, con la misma UI (`showOnAllDisplays`/`automaticallySwitchDisplay` de boring como referencia).
- **Fullscreen en la pantalla del notch:** hide-on-closed (altura→0 con su spring) cuando la app frontal está fullscreen ahí — honesto con la menu bar inexistente. Sneak peeks se suprimen. (No private `CGSSpace` en v1.)
- **Menu bar ítems reales:** jamás cubiertos en estado open — el panel abierto puede extenderse sobre la menu bar solo mientras está abierto y el pointer está en él; al cerrar vuelve a la silueta exacta. El closed JAMÁS cubre nada fuera del notch+4.
- **Pantalla sin notch con "modo notch" elegido:** fallback automático a una barra colapsada de 32 pt centrada arriba (el `nonNotchHeight` de boring) o a modo Dock — decisión de Settings.

---

## 8. Settings (catálogo completo, heredando el vocabulario del género)

- **Anclaje por pantalla:** Notch / Dock shelves / Off (por display) + "seguir al mouse" (auto-switch).
- **Activación:** hover on/off, delay slider, área de hover extendida, corredor de drag on/off.
- **Geometría:** altura del colapsado (real / menu bar / custom), profundidad abierta (320–560), corner radius scaling.
- **Comportamiento:** sneak peeks on/off + cadencia, abrir en la última pestaña, haptics on/off, gesto de cierre + sensibilidad, hotkey.
- **Privacidad:** ocultar de grabaciones de pantalla (`sharingType = .none` cuando la opción esté activa).

---

## 9. Invariantes duros (testeables, mismo estándar que la suite)

1. Closed ∩ (menu bar − notch) = ∅ — la silueta cerrada nunca cubre un píxel de menu bar fuera del notch (+4 de margen de clic es el máximo).
2. Closed ∩ (área de la cámara) = ∅ — siempre.
3. Open ⊆ screen — el panel abierto jamás sale de la pantalla (clamp con el mismo `ShelfGeometry.clamp`).
4. El estado closed es funcionalmente idéntico con 0 o 1000 ítems (el glance no cambia geometría, solo el punto de acento).
5. Cada transición cerrada↔abierta emite exactamente un spring retarget (nada de cadenas de timers — la lección WS-0/B3).
6. Con fullscreen activo en la pantalla del notch, la altura cerrada → 0 y no hay peeks.
7. Reduce Motion: sin morph de path ni sneak peeks; estados discretos con fade de 0.12 s.

---

## 10. Scoreboard (cómo sabremos que ganamos)

| Métrica | Meta |
|---|---|
| CPU en reposo | 0.0% (sin timers) |
| Drag→abierto listo | ≤ 150 ms desde que el drag entra al corredor |
| Morph cerrado→abierto | percibido como una pieza (0 frames de swap) |
| Precisión de silueta | cobertura exacta del notch con +4 pt de tolerancia de clic, 0 pt de mugre |
| Ítems que sobreviven a 24 h | todos (el anti-NotchDrop) |
| Veredicto subjetivo | "el notch es mi estante" |

---

## 11. Fases de construcción

- **Fase 1 — El ancla (spike → feature):** `NotchGeometry` (puro, testeado: medidas de pantalla → rects closed/peek/open), ventana del notch con silueta calibrada, hover/click/esc, morfo básico, hotkey. Criterio: la silueta es indistinguible del notch físico y el morph es un solo spring.
- **Fase 2 — El estante:** integrar `ShelfViewController` en el estado abierto (mount en frame 1), drop con corredor de arrastre, sneak peeks, glance de conteo, acciones completas.
- **Fase 3 — El sistema:** ancla por pantalla + fallback sin notch, hide-on-fullscreen, settings completos, haptics, hotkey, drag-out.
- **Fase 4 — Pulido:** morph con glass container (macOS 26), inercia de contenido afinada, corner radius scaling, passing del scoreboard.

Cada fase termina en build instalado + suites verdes + commit. La Fase 1 es la única con riesgo real de descubrimiento (calibración de silueta); todo lo demás es terreno que ya pisamos.
