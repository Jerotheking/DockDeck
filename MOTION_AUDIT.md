# Auditoría de Motion — DockDeck vs. competencia

**Fecha:** 2026-09-03 · **Alcance:** capa de motion completa (ventanas, contenido, tracking, material)
**Método:** lectura línea a línea de nuestro stack (`ShelfMotion`, `ShelfPanel`, `ShelfViewController`, `ShelfGeometry`, `DockWatcher`, `DockSensor`, `GlassInteractor`, `ShelfChrome`, tiles/rows) + investigación de competidores y del patrón de Apple.

---

## 1. Ground truth: qué encontramos de los competidores

### Dockside (hachipoo) — el referente directo
- **El bundle ya no existe en esta máquina** (solo queda el contenedor de grupo `8T2DC9NRXS.group.com.hachipoo.Dockside`, vacío). No fue posible inspeccionar su binario. `[VERIFICADO]`
- Su repo público en GitHub (`PrajwalSD/Dockside`) **no contiene código Swift** — solo traducciones y release notes. `[VERIFICADO]` La app comercial es closed-source; cualquier comparación de implementación es contra nuestra reconstrucción, no contra su código.
- De su documentación oficial (`thedockside.app/features`, `hachipoo.com`) sí extraemos decisiones de *producto* que explican su sensación de fluidez `[VERIFICADO en docs]`:
  1. **"Smart drag activation"** — el shelf se abre cuando *empiezas un drag* o cuando el puntero se *acerca*, con **sensibilidad y delay ajustables por el usuario**. No existe un solo timing duro; el usuario afina la respuesta.
  2. **"Shelf size: let width/height follow the Dock, or set them yourself"** — el tamaño sigue al Dock, pero el usuario puede anclarlo.
  3. **"Adapts when the Dock moves: resize and reposition when Dock size or screen layout changes"** — es exactamente el contracto que ya implementamos; no hay magia oculta ahí.
  4. **"Hide & fade: auto-hide and/or fade so the Dock strip stays calm"** — dos mecanismos de calma separados: esconder *y* desvanecer. Nosotros solo tenemos esconder.
  5. **"Expand and page through items"** — paginación en vez de lista infinita; la expansión es siempre del mismo tamaño → animaciones consistentes y predecibles.
  6. En r/DocksideApps el desarrollador confirma que explora **la API privada del Dock para replicar el material exacto** en light/dark — o sea: su ventaja visual no es un truco de AppKit público, es obsesión por el material.
- **Costo real de Dockside: $5.99 lifetime, macOS 13+, Swift nativo.** Su diferenciador no es una técnica secreta: es coherencia (un solo lenguaje de motion en cada superficie) + tolerancia de usuario configurable.

### Apple — el patrón que todos copian
- **Liquid Glass (WWDC25):** "reacts to movement with **specular highlights**", "dynamically reacts". El material no es estático: la luz se mueve con el contenido. Ya tenemos un glow — pero **solo** reacciona al puntero dentro del shelf, nunca a lo que pasa detrás.
- **`NSGlassEffectContainerView`** (macOS 26): fusiona instancias de glass cercanas en **una superficie continua con morph fluido** entre formas. Es LA API para que el shelf y su expansión se lean como *un solo material deformándose*, no como dos ventanas. No la usamos. `[VERIFICADO en docs Apple]`
- **La curva del Dock:** el magnify del Dock no es un spring global — cada icono escala según su **distancia al puntero con una curva gaussiana** (ver `buildui.com/recipes/magnified-dock` como reconstrucción moderna). Dos propiedades clave: (a) es **función directa del puntero, sin ningún retardo**; (b) la deformación es **local**, no global.
- **Morph sobre snap:** los componentes de Apple rara vez hacen crossfade entre estados distintos; deforman la misma superficie de A a B (sheet que crece desde su botón, paneles que se pliegan). El crossfade es lo que usamos en collapsed↔expanded — es el patrón "barato" del lenguaje.

**Conclusión del benchmark:** no nos falta una técnica secreta. Nos falta: (1) cero latencia percibida en el seguimiento, (2) un solo material que se deforme en vez de estados que se funden, (3) motion de contenido (inserciones/movimientos), no solo motion de ventana, y (4) curvas afinadas donde importa.

---

## 2. Auditoría de nuestro stack, capa por capa

### 2.1 Motor de springs — `SpringAnimator` ✅ bien, con un defecto de fondo
**Lo bueno (y es mucho):** integrador semi-implícito propio, retargeting con conservación de posición+velocidad (`retarget(to:)`), display link a tasa de refresco, epsilon de settle, Reduce Motion respetado, snap para correcciones sub-píxel. Esto es arquitectura correcta — el problema nunca fue el motor.

**Defecto estructural [GRAVE]:** el animator **solo mueve el frame de la ventana**. Toda la magia del retarget con velocidad heredada se aplica a un rectángulo; el contenido interior (tiles, rows, scroll) no participa: no hereda velocidad, no se estira, nada. Apple mueve *material*; nosotros movemos *marcos*. Es la raíz de "las animaciones no me satisfacen": la superficie fluye y el contenido va pegado con cinta.

**Defecto secundario:** `SpringAnimator.step` integra las 4 componentes con el **mismo parámetro**, así que un resize mientras se mueve (magnificación) mete el overshoot del resize en el eje de posición: durante la magnificación el shelf "rebota" también horizontalmente, lo que se lee como gelatina mal mezclada. Los ejes deben poder disociarse (posición rígida `.track`, tamaño líquido).

### 2.2 Presets — valores de spring
| Preset | response | damping | Veredicto |
|---|---|---|---|
| `.track` | 0.13 | 0.95 | ✅ Correcto — casi crítico y rápido |
| `.reveal` | 0.30 | 0.78 | ⚠️ El overshoot en una *aparición* se ve como error, no como vida |
| `.expand` | 0.42 | 0.68 | ⚠️ El más "bailable": ~0.42 s + rebote notorio. Con expansión a 320 pt de profundidad, el rebote desplaza los rows ~20 pt de más — se siente *wobbly*, no líquido |
| `.collapse` | 0.24 | 0.85 | ✅ Razonable |
| `.slide` | 0.45 | 0.90 | ⚠️ 0.45 s es *lento* para una reubicación estructural; el Dock cambia de lado y el shelf llega tarde |

El error de carácter: **invertimos la energía**. En el lenguaje Apple, las gesturas *dirigidas por el usuario* (expansión al hover) son rápidas y levemente overdamped; las gesturas *ambienales* (el float perpetuo, el glow) son las que se dan el lujo. Nosotros pusimos el lujo en la gestura principal y la rigidez en el fondo. Además: `reveal` con 0.78 de damping sobre un window-frame con `hasShadow = true` — la sombra sigue al frame y amplifica visualmente el overshoot.

### 2.3 `ShelfPanel` — ciclo de expansión
1. **`expand()` no sincroniza con el contenido.** El panel lanza su spring inmediato, pero el contenido expandido solo se monta cuando `setPresentation` llega vía `onStateChange` → `applyPresentation`, que además espera **80 ms extra** (`asyncAfter 0.08`) antes de fundir y lanzar arrivals. Total: la ventana ya viajó ~30–40 % de su recorrido cuando el primer row siquiera existe. Ese hueco *es* la sensación de "fluido raro": el ojo ve vidrio vacío estirándose.
2. **Crossfade collapsed↔expanded** (`applyPresentation` 0.16 s): confesado en el propio comentario del código ("reflowing produces a frame of garbage"). Es una rendición, no una decisión. Con `NSGlassEffectContainerView` + un layout único flexible, el morph es factible; sin él, el crossfade de dos stacks AppKit es el techo.
3. **`collapseDelay` fijo 0.45 s** y `expandOnHover` binario: cero sensibilidad. Dockside expone delay y zona; nosotros un número compilado. El "flap" (abrir/cerrar nervioso al rozar el borde) viene de aquí.
4. **`contentScale` clamp ≤ 1** — correcto en concepto, pero significa que cuando el Dock se hace *más grande* (auto-hide reveal, o agrandar el Dock), el shelf colapsado primero muestra iconos pequeños y luego "salta" al re-derivarse `tileSize`. El crecimiento nunca es continuo, solo el encogimiento.
5. **`level = .mainMenu` (24)**: por encima del Dock, pero también por encima de menús de otras apps en casi todos los casos visuales; no es la causa de "no fluye", pero es una decisión agresiva que conviene revisar junto al material.

### 2.4 `DockWatcher` — la latencia real está aquí
Esta es la capa que explica "no se adecua al tamaño del dock" en build 9:

1. **[CRÍTICO — reentrancia]** `evaluate()` mide con `DockGeometry.current()` → una lectura AX **síncrona** (dos `AXUIElementCopyAttributeValue` IPC al Dock). El `AXObserver` dispara `evaluate()` **por cada evento del Dock**. Durante la magnificación el Dock emite decenas de eventos/seg → decenas de lecturas AX síncronas encoladas → la main thread se ahoga → **el UI congelado y CPU al 10 GB que viste en build 9 nació aquí**, y ninguna animación puede verse fluida sobre un runloop asfixiado. `[INFERIDO del código; consistente con el síntoma reportado]`
2. **El timeout de confirmación (0.15 s) se arma por evento** (`asyncAfter + evaluate`) en cada lectura transitoria — una cascada de timers que se re-disparan entre sí. Es una máquina de estados escrita con timers, no con un modelo.
3. **Doble reporte por lectura** (transiente + confirmación inmediata cuando `!pointerOnDock`): el panel puede recibir dos `onChange` en el mismo runloop tick → dos `animate()` seguidos → micro-jerk en el primer frame.
4. `pointerThrottle = 0` con `Date()` alloc por evento de mouse: barato pero continuo; junto con (1) contribuye a la tormenta.

### 2.5 `DockSensor` — neto de eventos demasiado grande
Subscribimos **9 tipos de notificación** incluyendo `AXValueChanged` en el item list (que el Dock emite *por tile* en muchos cambios) y `AXTitleChanged`. El Dock puede reventar el árbol AX al relayout (p. ej. al magnificar reconstruye ventanas) → tormenta de eventos → ver 2.4.1. **El sensor debe coalescer**: una ventana de ~30–50 ms que fusiona ráfagas en una sola evaluación, o como máximo un flag "dirty + pending evaluation" en el runloop. Nunca una lectura AX por notificación.

### 2.6 `GlassInteractor` + `MaterialLayerStyles` — el material
- El glow sigue al puntero **por saltos** (`moveGlow` asigna `position` directo): sin interpolación, el bloom teletransporta entre muestras de mouse. Debe lerpear (CASpring o display link compartido).
- `setFloatingMotion` (drift de 1.5 pt en 3.4 s, `easeInEaseOut` lineal repetido): en loop se nota el "reset" de la keyframe — un latido con patrón visible. Un float elegante necesita dos ejes con **periodos inconmensurables** (p. ej. 5.3 s y 7.1 s) para que el ciclo compuesto no repita jamás.
- **El glow no reacciona al Dock.** Es el highlight especular de Liquid Glass y está ciego al evento más dramático del sistema: la magnificación. Cuando el Dock crece, la luz debería *inclinarse* hacia él. `[frente al patrón Apple]`
- `setPressed`: `layer.transform = ...0.92` mientras la animación `press` sigue corriendo — patrón AppKit correcto, pero al soltar, `releasePressed` arranca **desde 0.92 fijo** (`toValue: 1.0`, fromValue leído del modelo no de la presentación). Si sueltas a mitad del press, hay un salto de 1 frame.

### 2.7 Contenido — tiles y rows: **la capa más atrasada**
1. **`renderTiles` / `renderRows` destruyen y reconstruyen todo** (`arrangedSubviews.forEach { $0.removeFromSuperview() }`). Copiar algo al portapapeles reconstruye la tira completa: **ningún icono nuevo entra animado**, los demás parpadean (re-creación de vistas). Dockside hace "visual item tracking" y batch-drop con stacks. Esto es el fix #1 de sensación de calidad: **diffing + inserciones animadas** (o `NSCollectionView` con diffable data source, que anima insert/move/delete gratis).
2. **El hover del tile (1.14×)** es el único movimiento de contenido — bien afinado (`reveal` spring) pero un孤 isolated. No hay tilt, no hay reacción al vecino (el Dock magnifica *toda la fila* según distancia; nuestro tile solo escala a sí mismo).
3. **Thumbnails crossfade 0.15 s** ✅ — este es el estándar de detalle que falta en el resto.
4. Filas expandidas: botones de acción aparecen/desaparecen **sin animación** (`isHidden = true/false` directo) — un pop seco en la superficie más visible del shelf expandido.

### 2.8 Geometría — `ShelfGeometry`
✅ Sólida: pura, testeada (177 checks), contratos claros (compress/weld/sidecar). Un detalle: `contentScale = room/thickness` hace que el contenido *escoja* su escala de la lectura transitoria; como la lectura AX puede llegar ya coalesced (ver 2.4), el contenido puede saltar entre escalas en pasos visibles en vez de respirar. Con el watcher arreglado, esto queda bien; sin arreglarlo, amplifica el jitter.

---

## 3. Los bugs de fluidez concretos (lista de ataque, priorizada)

| # | Bug | Evidencia | Impacto en sensación |
|---|---|---|---|
| B1 | **Tormenta AX→evaluate sin coalescing** — 1 lectura AX IPC por notificación del Dock, re-entrante con los timers de confirmación | `DockWatcher.evaluate()` + `DockSensor` (9 notifs) | CPU runaway (lo viviste), UI stutter: *nada* puede verse fluido encima de esto. **Es el bug #1.** |
| B2 | **El contenido no participa del motion** — springs mueven solo el frame; rows/tiles van rigid attach | `SpringAnimator` (window-only), `applyPresentation` crossfade | "Se siente vacío/mecánico": vidrio que fluye con contenido congelado |
| B3 | **Hueco de 80 ms + crossfade en expansión** — contenido monta tarde, fade lento | `ShelfViewController.applyPresentation` (asyncAfter 0.08, 0.24 fade) | El pop no "sale del Dock"; se abre un cajón vacío |
| B4 | **Reconstrucción total de tiles/rows sin diff** | `renderTiles`, `renderRows` | Sin animación de entrada para items nuevos; parpadeo en cada cambio |
| B5 | **`reveal`/`expand` overshoot sobre sombra + ventana** — rebote se lee como error | presets 0.78/0.68 damping, `hasShadow` | Wobble barato en vez de liquid |
| B6 | **Glow teletransporta** sin interpolar | `GlassInteractor.moveGlow` | El efecto "vivo" se ve con tics |
| B7 | **Float perpetuo con ciclo visible** | `setFloatingMotion` 3.4 s ease lineal | Se percibe el loop = falso |
| B8 | **`slide` 0.45 s** para reubicaciones; el shelf llega tarde al Dock | preset `.slide` | "No se adecua" en cambios de orientación/posición |
| B9 | **Crecimiento discontinuo**: contentScale ≤1 solo encoge; crecer = saltar a tileSize nuevo | `ShelfGeometry.contentScale` + re-layout por confirmación | Al agrandar el Dock el shelf da un brinco |
| B10 | **Botones de fila sin fade** (`isHidden` directo) | `ShelfRowView.mouseEntered/Exited` | Pop seco en la vista más mirada |
| B11 | **Ejes acoplados en el spring del frame** — resize mete rebote en posición | `SpringAnimator.step` | Gelatina mal mezclada durante magnificación |
| B12 | **Flap en el borde**: delay fijo 0.45 s, sin zona de activación configurable | `collapseDelay`, sin hysteresis espacial | Nerviosismo al rozar el shelf |

---

## 4. Diagnóstico de fondo (el porqué de todo)

Nuestro motion está construido **ventana-primero**: invertimos en el motor de springs del frame (excelente) y dejamos el contenido como un vecino que se entera tarde. La competencia y Apple construyen **material-primero**: la superficie y su contenido son una sola cosa que se deforma, y el tracking es una función continua del puntero sin estados intermedios. Complemento necesario: **el runloop manda** — ningún preset puede verse bien sobre una capa de sensor que inunda la main thread.

---

## 5. Recomendaciones priorizadas

### P0 — Desatascar el sistema (hace posible todo lo demás)
1. **Coalescer el sensor**: el callback del AXObserver solo marca `needsEvaluation` y agenda **una** evaluación por runloop tick (o ventana de 30–50 ms). Eliminar `AXValueChanged`/`AXTitleChanged` de la subscripción (no aportan geometría). `evaluate()` debe ser **idempotente y no re-entrante**: un solo `DockGeometry.current()` por tick, sin timers de confirmación en cascada (reemplazar por "promoción si la lectura se repite N ticks").
2. **Un solo pipeline de lectura → decisión**: medir en el tick coalesced, clasificar, emitir **a lo sumo un** `onChange` por tick.

### P1 — Material-primero (donde vive el "wow")
3. **Difundir el motion al contenido**: pasar el vector (posición, velocidad) del spring del panel a un `contentMotion` aplicado a `contentScaleHost` (contra-scale sutil + skew mínimo proporcional a la velocidad) — el contenido hereda la inercia de la superficie. Es lo que más acercaría el feel al Dock real.
4. **Morph de expansión, no crossfade**: adoptar `NSGlassEffectContainerView` (macOS 26) para que collapsed y expanded sean dos glass views del mismo container — la fusión/morph del material lo hace el sistema. Fallback: acortar el hueco (montar expanded inmediatamente, fade 0.10 s) y arrancar arrivals en el primer frame.
5. **Curva local de hover para tiles**: escala del tile según **distancia del puntero a cada tile** (gaussiana compacta, radio ~1.5 tiles) — el mismo principio del Dock. Con un display link compartido mientras el puntero esté sobre la tira.
6. **Diffing de contenido**: insertar tiles/rows nuevos con arrival animado, mover con fade-through, solo tocar lo que cambió. (O migrar las listas a `NSCollectionView` + diffable.)
7. **Glow con interpolación** (spring corto hacia el puntero) + **reacción al Dock**: inclinar el eje del glow con la magnificación actual.

### P2 — Afinado de carácter
8. Rebalance de presets: `reveal` → (0.26, 0.90), `expand` → (0.34, 0.86), `slide` → (0.32, 0.92); overshoot reservado al *contenido* (arrivals), no al frame. Sombrear menos el overshoot: `hasShadow` con radio menor durante springs.
9. **Ejes disociados** en `SpringAnimator` (posición `.track`, tamaño `.expand` por componente).
10. **Hysteresis espacial**: expandir con entrada de ~8 pt, colapsar tras salir ~28 pt + delay; delay y zonas expuestos en Settings (el "drag sensitivity" de Dockside).
11. **Crecimiento continuo**: cuando thickness crece, animar `contentScale` por encima de 1 brevemente (clamp de layout ya protege) en vez de saltar a tileSize nuevo.
12. Fade de botones de fila (0.12 s) y fade+slide del overflowLabel.

### No hacer
- **No** perseguir la API privada del Dock (material exacto): es lo que hace Dockside, pero nos expone a breakage en cada macOS; nuestro `NSGlassEffectView` + glow propio es la vía pública correcta.
- **No** más timers de confirmación: el tiempo de confirmación debe salir del *modelo* (lecturas repetidas), no de `asyncAfter`.
