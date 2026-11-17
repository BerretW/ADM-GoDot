# ADM Cross-Engine Showcase

Godot tester pro validaci souborů ADM 1.0; společný backlog Godot/Unreal je v [docs/TASKS.md](docs/TASKS.md).

## Spuštění

- Vyžaduje Godot **4.7.2-stable**.
- Otevřete `project.godot` v Godotu a spusťte projekt.
- Zvolte libovolný soubor `.adm` nebo `.adm_anim`; validátor zobrazí stav, diagnostiku, deklarovaná rozšíření a hash assetu.
- U podporovaných modelů se zobrazí **diagnostický statický 3D náhled**. Tažením levým tlačítkem otáčíte kamerou, kolečkem přibližujete.
- **Povolit neúplný diagnostický náhled** je ve výchozím stavu zapnuté, takže lze otevřít i `ADM/humanoid.adm` s nepodporovaným povinným rozšířením. Validace i runtime zůstávají `unsupported` a nad náhledem je varování; nejde o plnou podporu modelu. Po vypnutí se náhled takového modelu skryje, po zapnutí znovu načte.
- **Zobrazit rámce kloubů** je ve výchozím stavu vypnuté. Pokud výchozí scéna obsahuje `ADM_joint_display_v1`, přepínač zobrazí autorské body head/tail tyrkysově a orientaci rámce osami X/Y/Z červeně/zeleně/modře. Číslo rámců i stav přepínače jsou v reportu `preview.jointDisplay`. Chybějící tvary se z hierarchie neodhadují.
- Tlačítkem **Exportovat JSON report** uložte strojově čitelný report.
- Smoke test spustíte z kořene projektu:

  ```powershell
  .\GoDot\Godot_v4.7.2-stable_mono_win64_console.exe --headless --path . --script res://tests/run_tests.gd
  ```

  Test vytvoří `reports/validation-smoke.json` a zaznamená commit použité specifikace.

- Soubory nahrané do `ADM` lze ověřit hromadně bez jejich změn:

  ```powershell
  .\GoDot\Godot_v4.7.2-stable_mono_win64_console.exe --headless --path . --script res://tests/run_assets.gd
  ```

  Výsledky a SHA-256 jednotlivých souborů jsou v `reports/uploaded-assets.json`. Test kontroluje očekávaný výsledek pro `triangle.adm`, `shader_layered.adm` a `humanoid.adm`; pro ostatní soubory zaznamenává diagnostiku bez předpokladu úplné validity. Nahrané soubory nemají ověřený upstream commit.

- Náhled geometrie a hierarchie lze testovat bez grafického prostředí:

  ```powershell
  .\GoDot\Godot_v4.7.2-stable_mono_win64_console.exe --headless --path . --script res://tests/run_preview.gd
  ```

  Výsledek a limity jsou v `reports/preview-smoke.json`. Pro kontrolu skutečného vykreslení se spuštěným grafickým prostředím použijte:

  ```powershell
  .\GoDot\Godot_v4.7.2-stable_mono_win64_console.exe --path . --rendering-method gl_compatibility --script res://tests/run_preview_render.gd
  ```

  Test ověří i výchozí stav a přepínání diagnostického náhledu; uloží `reports/humanoid-ui-test.json` a `reports/humanoid-preview.png`. Pokud `human.adm` odpovídá testovanému hashi, ověří 67 autorských rámců i viditelný účinek textury a masky `COLOR_1.R`; uloží také `reports/human-preview.json` a `reports/human-preview.png`. Jde o diagnostické, nikoli referenční snímky.

## Aktuální milník

Současný milník pokrývá kontrolu hlavičky, adresáře chunků, rozsahů, zarovnání, RAW SHA-256, JSON manifestu, buffer views, accessorů a základních metadat animační knihovny. Validuje také `chunkDependencies` a `streamHints` dle § 5: odmítá chybné odkazy, duplicity a cykly a hlásí nedostupné nepřímé závislosti potřebných chunků. `supported` označuje pouze formátovou a validační schopnost tohoto milníku; neznamená připravenost assetu k vykreslení.

Náhled vykresluje RAW trojúhelníky, transformace hierarchie, normály a částečný materiálový fallback: základní barvu a emisní výstup včetně vložených PNG/JPEG textur, `TEXCOORD_0` nebo `TEXCOORD_1`, číselné faktory metallic/roughness a režimy alpha. U KTX2/DDS použije deklarovaný PNG/JPEG `fallbackSource` a zkontroluje shodu rozměrů podle hlaviček; GPU kontejnery nedekóduje ani plně nevaliduje. Podporuje shodné filtry NEAREST nebo LINEAR a shodný wrap REPEAT nebo CLAMP_TO_EDGE pro obě osy; jiné kombinace jsou hlášeny jako nepodporované a textura se nezobrazí. Různé UV nebo samplery základní a emisní textury zatím nejsou současně podporovány; v takovém případě je emise vypnutá a nahlášená. Emisní výstup sám o sobě neznamená bloom/glow ani osvětlení okolí. Vstupní obraz je omezen na 8192 bodů v jedné ose a 16 777 216 pixelů. Chybějící normály se pro náhled dopočítávají.

Diagnostika kloubů používá `W_node × displayFrame` a přesný autorský `tail`, bez změny uzlů nebo skinningu. Zobrazuje jen výchozí scénu a klidovou pózu; délka barevných os je pouze vizualizační. Při načítání náhledu kontroluje strukturu a povinnou přítomnost dat kloubů; prokazatelně chybná data označí `invalid`, problémy číselného rozsahu ohlásí jako nedostupný náhled. Samostatný validátor tuto kontrolu zatím neprovádí. Výpočty náhledu používají numerickou přesnost Godotu; zachování dat při importu/exportu a úplná validace nejsou implementovány, proto se nehlásí schopnost `ADM-JOINT-DISPLAY-1`.

U modelu s povinným `ADM_vertex_control_v1` a přesným shaderem `adm.pbr.metallic_roughness@2.1.0` diagnostický režim navíc zobrazuje autorskou detailovou barvu a texturu drsnosti přes masku `COLOR_1.R`, včetně PNG/JPEG fallbacku. Zatím jen pro neprůhledné materiály se shodnými UV a samplerem LINEAR/REPEAT. Ostatní kanály, normal mapy, metalické mapy a ostatní efekty vertex-control se nevykreslují. Jde o **částečný diagnostický shader**, nikoli o běžný PBR fallback ani plně podporovaný shader; report uvádí `shaderRendering: partial_diagnostic`, `shaderSupported: false` a `shaderFallbackActive: false`. Mimo tento diagnostický režim zůstává standardní fallback beze změny.

Nejde o úplnou implementaci PBR: chybí textury metallic-roughness, normál a occlusion, přesné chování oboustranných materiálů a pokročilé shadery. Report uvádí přesnou identitu shaderu a příznaky `shaderSupported`/`shaderFallbackActive`; při částečném fallbacku není podpora shaderu tvrzena. Nadále chybí úplná podpora vertex barev, morph, skinning, animace, IK, kolize, nativní dekódování KTX2/DDS a ZSTD. Animační knihovna se validuje samostatně, nepřehrává se. Úplná validace sémantiky modelu a animačních kanálů rovněž chybí. Soubor se načítá celý; částečné načítání ani `ADM-STREAM-1` nejsou implementovány. Volitelná nepodporovaná rozšíření jsou diagnostikována a zachována v exportovaném manifestu; povinná nepodporovaná rozšíření vedou ke stavu `unsupported`. Neplatná struktura vede ke stavu `invalid`.

Pokud je v `ADM` soubor `human.adm` s očekávaným hashem, test náhledu ověří jeho emisní, detailový a drsnostní PNG fallback i 67 rámců a zaznamená hash i omezení do `reports/preview-smoke.json`. Model zůstává `unsupported`: vyžaduje `ADM_joint_display_v1` a `ADM_vertex_control_v1`; jeho shader `adm.pbr.metallic_roughness@2.1.0` je podporován pouze v uvedeném diagnostickém rozsahu a skinning není implementován. Shaderové textury nejsou zaměňovány za nezávislý PBR fallback.

Ověřená normativní specifikace: [`ADM-1.0-SPEC.md`](https://github.com/BerretW/ADM/blob/0fe5ac81683584683a6d83b40bf779d6d219cde5/adm-standard/ADM-1.0-SPEC.md), commit `0fe5ac81683584683a6d83b40bf779d6d219cde5`.

Zdroj pravdy: https://github.com/BerretW/ADM
Normativní specifikace: https://github.com/BerretW/ADM/blob/main/adm-standard/ADM-1.0-SPEC.md

Před každou etapou ověř aktuální specifikaci na main; žádné požadavky enginu nesmí měnit význam ADM. Oba testery musí načítat identické referenční soubory z ADM repozitáře.

Pořadí: 1. validace a diagnostika, 2. načtení a rendering, 3. materiály/textury, 4. animace, 5. IK laboratoř, 6. schody a den/noc, 7. modulární zbraň, 8. automatické porovnání výsledků.

Podrobnosti v docs/TASKS.md a docs/ASSET_CONTRACT.md.
