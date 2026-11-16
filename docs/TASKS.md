# Společný backlog: ADM Godot + ADM Unreal

Každý úkol platí pro OBA enginy; udržujte identické názvy ovládacích prvků a testovacích scénářů, pokud to jde.

## P0 — základ
- [ ] Přečíst aktuální ADM specifikaci, zaznamenat commit SHA a sestavit matici podporovaných profilů/rozšíření.
- [ ] Runtime loader a validace hlavičky, adresáře chunků, hashů, komprese, manifestu, bufferViews a accessors.
- [ ] Tester: výběr .adm a .adm_anim, výpis vlastností, diagnostika chyb, načtení bez ztráty neznámých volitelných metadat.
- [ ] Render: geometrie, node transformace, PBR materiály, textury, COLOR_0/COLOR_1 pouze dle platných rozšíření, morph, skeleton.
- [ ] Ovládání: výběr uzlu, změna tintu a dalších podporovaných parametrů, přepnutí texture bindingu, zobrazení původní a výsledné textury; export původních zakódovaných dat i dekódovaného obrazu s jasným označením.
- [ ] Animační knihovny: výběr klipu, play/pause/seek/speed, parametry shaderů, event markers, retarget, blend podle deklarované podpory.

## P1 — Interactive IK Test Lab
- [ ] Přepínač IK ON/OFF a viditelné kostry, effector target gizma a pole vector gizma.
- [ ] Manipulace myší v 3D, numerické zadání targetu v MODEL space, změna weight 0–1.
- [ ] Ukázat dosažitelný interval, SOLVED/CLAMPED, skutečnou koncovou pozici, endpoint error.
- [ ] Otestovat nulový target, přímý/opačný směr, singularity, nedosažitelný target, pole degeneracy, váhu 0 a 1.
- [ ] Referenční ADM-IK-1 jako primární solver; volitelně nativní IK enginu vedle pro srovnání. Nezaměňovat pozici s orientací koncového kloubu.
- [ ] JSON test report s tolerancemi dle specifikace.

## P1 — schody a materiály
- [ ] Rovné schodiště a točité schodiště načíst jako ADM z centrálního repozitáře.
- [ ] Jedna běžná animace chůze postavy pro rovinu i schody; žádná zvláštní schodová animace.
- [ ] Engine raycastem určuje kontakt, fázi kroku, target nohy a případný posun pánve; ADM poskytuje data a TWO_BONE řešení, ne gameplay chování.
- [ ] Přepínač IK ON/OFF, vizualizace targetů a kontaktů, logování klouzání nohou a chyb dosahu.
- [ ] Přepínač den/noc: mění osvětlení scény (engine). Samostatně přepínače emise ON/OFF, barva, intenzita, test blikání a plynulé změny pomocí ADM animovaných materiálových parametrů, pokud je specifikace dovoluje.
- [ ] Oddělit výsledky emissive shaderu od post-process bloom a GI; uvést renderovací omezení Godot/Unreal.
- [ ] Srovnávací screenshoty ve stejném čase animace, stejných hodnotách parametrů a stejném osvětlení (s popisem rozdílů rendererů).

## P2 — modulární zbraň a přebíjení
- [ ] Načíst postavu, základ zbraně a volitelné součásti jako ADM modely, připojit přes ADM attachment markers / komponenty dle specifikace.
- [ ] UI výměny zásobníku, optiky, hlavně, pažby a další deklarované kompatibilní součásti.
- [ ] Přebíjení: běžný animační klip + IK ruky směrem k definovanému bodu na zbrani; časování výměny a volba součástí jsou pouze engine gameplay logika.
- [ ] Test změny tintu, materiálů, textur, případných emisních prvků zbraně.
- [ ] Kontrola konzistence pozic attachment markerů, animací a IK napříč enginy.

## P3 — ověření a publikace
- [ ] Automatický testovací běh všech dostupných referenčních modelů a negativních testů.
- [ ] Export JSON/CSV souhrnu schopností, neimplementovaných profilů, přesnosti IK, hashů a snímků.
- [ ] Dokumentace kroků spuštění, klávesových zkratek, známých rozdílů, omezení a minimálních verzí enginů.
- [ ] CI build a smoke test na každé změně, tam kde je dostupný headless běh.

## Kritéria přijetí
1. Stejný nezměněný ADM asset lze otevřít v obou testerech.
2. Každý podporovaný parametr lze ověřit vizuálně nebo numericky; nepodporované funkce jsou přiznané.
3. IK výsledek odpovídá ADM-IK-1 v tolerancích normativní specifikace.
4. Schody fungují s jediným chodeckým klipem; tester jasně odlišuje korekci IK od logiky enginu.
5. Emisní efekty mají deterministické vstupy a jsou oddělené od renderer-specific bloom/GI.
6. Modulární zbraň využívá ADM data a engine-only interakční logiku.
