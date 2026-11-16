# ADM Cross-Engine Showcase

Godot tester pro validaci souborů ADM 1.0; společný backlog Godot/Unreal je v [docs/TASKS.md](docs/TASKS.md).

## Spuštění

- Vyžaduje Godot **4.7.2-stable**.
- Otevřete `project.godot` v Godotu a spusťte projekt.
- Zvolte libovolný soubor `.adm` nebo `.adm_anim`; validátor zobrazí stav, diagnostiku, deklarovaná rozšíření a hash assetu.
- U podporovaných modelů se zobrazí **diagnostický statický 3D náhled**. Tažením levým tlačítkem otáčíte kamerou, kolečkem přibližujete.
- **Povolit neúplný diagnostický náhled** je ve výchozím stavu zapnuté, takže lze otevřít i `ADM/humanoid.adm` s nepodporovaným povinným rozšířením. Validace i runtime zůstávají `unsupported` a nad náhledem je varování; nejde o plnou podporu modelu. Po vypnutí se náhled takového modelu skryje, po zapnutí znovu načte.
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

  Test ověří i výchozí stav a přepínání diagnostického náhledu; uloží `reports/humanoid-ui-test.json` a `reports/humanoid-preview.png`. Jde o diagnostický, nikoli referenční snímek.

## Aktuální milník

První milník pokrývá kontrolu hlavičky, adresáře chunků, rozsahů, zarovnání, RAW SHA-256, JSON manifestu, buffer views a základních metadat animační knihovny. `supported` označuje pouze formátová a validační schopnost tohoto milníku; neznamená připravenost assetu k vykreslení.

Náhled vykresluje RAW trojúhelníky, transformace hierarchie, normály a částečný materiálový fallback: základní barvu a její vloženou PNG/JPEG texturu, `TEXCOORD_0` nebo `TEXCOORD_1`, číselné faktory metallic/roughness a režimy alpha. Podporuje shodné filtry NEAREST nebo LINEAR a shodný wrap REPEAT nebo CLAMP_TO_EDGE pro obě osy; jiné kombinace jsou hlášeny jako nepodporované a textura se nezobrazí. Vstupní obraz je omezen na 8192 bodů v jedné ose a 16 777 216 pixelů. Chybějící normály se pro náhled dopočítávají.

Nejde o úplnou implementaci PBR: chybí textury metallic-roughness, normál, occlusion a emise, emisní výstup, přesné chování oboustranných materiálů a pokročilé shadery. Report uvádí přesnou identitu shaderu a příznaky `shaderSupported`/`shaderFallbackActive`; při částečném fallbacku není podpora shaderu tvrzena. Nadále chybí vertex barvy, morph, skinning, animace, IK, kolize, KTX2/DDS a ZSTD. Animační knihovna se validuje samostatně, nepřehrává se. Úplná validace sémantiky modelu a animačních kanálů rovněž chybí. Volitelná nepodporovaná rozšíření jsou diagnostikována a zachována v exportovaném manifestu; povinná nepodporovaná rozšíření vedou ke stavu `unsupported`. Neplatná struktura vede ke stavu `invalid`.

Ověřená normativní specifikace: [`ADM-1.0-SPEC.md`](https://github.com/BerretW/ADM/blob/0c6e9539c4e3b8cc7d8249ebed7bcfcfe12e9167/adm-standard/ADM-1.0-SPEC.md), commit `0c6e9539c4e3b8cc7d8249ebed7bcfcfe12e9167`.

Zdroj pravdy: https://github.com/BerretW/ADM
Normativní specifikace: https://github.com/BerretW/ADM/blob/main/adm-standard/ADM-1.0-SPEC.md

Před každou etapou ověř aktuální specifikaci na main; žádné požadavky enginu nesmí měnit význam ADM. Oba testery musí načítat identické referenční soubory z ADM repozitáře.

Pořadí: 1. validace a diagnostika, 2. načtení a rendering, 3. materiály/textury, 4. animace, 5. IK laboratoř, 6. schody a den/noc, 7. modulární zbraň, 8. automatické porovnání výsledků.

Podrobnosti v docs/TASKS.md a docs/ASSET_CONTRACT.md.
