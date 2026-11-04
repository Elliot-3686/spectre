# Journal de progression — Spectre

## État au 4 novembre 2026

| Étape | État | Vérifié par |
|---|---|---|
| Cœur DSP (FFT multi-résolution, pics, notes, dBFS, true peak) | ✅ fini | 13 tests unitaires sur macOS (CI) |
| Capture Spotify par process tap Core Audio (14.2+) | ✅ écrite et compilée | ⚠️ **non testée avec le vrai Spotify** (pas d'audio sur la CI) |
| Secours ScreenCaptureKit (macOS 13 – 14.1) | ✅ écrit et compilé | ⚠️ non testé |
| Attente de Spotify, reconnexion auto, pause, permission refusée | ✅ écrit (notifications, sans scrutation) | ⚠️ non testé avec le vrai Spotify |
| Rendu Metal : Liquide, Sable, Courbe, Tiers d'octave, Spectrogramme | ✅ fini | captures générées par la CI (GPU virtuel) |
| Thèmes Sobre, Monochrome, Braise (OKLab) | ✅ fini | tests de palette + captures |
| Fond d'écran (niveau bureau, tous les Spaces, clics ignorés, choix d'écran) | ✅ écrit | lancé sur la CI en mode démo ; ⚠️ aspect réel sur le bureau non vu |
| Menu de la barre des menus, réglages, lancement à l'ouverture de session | ✅ écrit | compilé ; ⚠️ non manipulé à la main |
| Cadence adaptative, 0 i/s au repos, pause sur verrouillage/veille/occlusion | ✅ fini | mesuré sur la CI (repos ≈ 0,1 % de CPU, 0–2 réveils/s) |
| Mode économie automatique sur batterie / mode économie d'énergie | ✅ écrit | ⚠️ non testé (pas de batterie sur la CI) |
| Mode démo, outil Diagnostic (mesure réelle sur votre Mac) | ✅ fini | utilisés par la CI |

## Précision (tests `Packages/SpectreCore`, exécutés sur macOS 15.8 par la CI)
- **Sinus purs** à 50 ; 82,41 ; 123,47 ; 440 ; 1000 ; 5000 ; 15000 Hz, plus des fréquences hors bin (50,37 ; 440,21 ; 997,3 ; 4999,7 ; 15013,3 Hz). Quatre configurations testées : multi-résolution, 8192 seule, économie 4096, et 44,1 kHz.
  - Erreur maximale **0,0009 Hz** (50,37 Hz en 8192 seule), le plus souvent < 0,0001 Hz. Exigence : 0,1 Hz sous 1 kHz, 0,1 % au-dessus.
  - Niveau −6,021 dBFS pour une amplitude de 0,5, soit une erreur < 0,005 dB.
- **440 Hz → A4 +0 cents** et **1000 Hz → B5 +21 cents**, avec une erreur < 0,0001 Hz.
- **Calibrage** : sinus pleine échelle = 0,000 dBFS avec les fenêtres Hann, Blackman-Harris et flat-top. La crête vraie vaut 0,000 dBTP.
- **Accord** (220 ; 277,18 ; 329,63 ; 440 ; 1318,51 Hz) : les 5 notes sont trouvées à ±0,002 Hz près.
- **Bruit rose** en tiers d'octave, de 40 Hz à 10 kHz : plat à ±0,7 dB.
- **Balayage logarithmique** de 20 Hz à 20 kHz en 20 s : erreur relative maximale de 1,2 % (graves), 0,43 % (médiums) et 0,23 % (aigus). Une fréquence qui glisse s'étale dans la fenêtre longue, d'où l'erreur plus grande dans les graves.

## Consommation (mesures réelles, mais sur un Mac **virtuel** : M1 virtuel, GPU paravirtualisé)
Voir `docs/benchmark.md` et `docs/cpu.md`.
- **Analyse seule** (1 cœur) :
  - Haut : 32768/8192/2048 à 60 i/s → 0,5 %
  - Moyen : 16384/4096 à 30 i/s → 0,2 %
  - Économie : 4096 à 20 i/s → 0,06 %
- **GPU** pour le fond d'écran Moyen à 2560×1440 et 30 i/s : 6 à 14 % du GPU virtuel selon le mode. En Économie : 3 à 6 %.
- **App complète, mode démo** (CPU du processus, getrusage) :
  - fenêtre + fond d'écran pendant la musique : 11,4 % ;
  - fond d'écran seul pendant la musique : 7,9 % ;
  - **au repos (Spotify absent ou en pause) : 0,11 %**, 0 image et 0 FFT.
  - powermetrics donne un « Energy Impact » de 7 à 12 pour Spectre sur cette VM.
- ⚠️ **L'objectif de moins de 2 % de CPU en fonctionnement n'est pas démontré.** Sur la VM, l'essentiel du coût semble venir du pilote GPU paravirtualisé et du compositeur virtuel : la seule partie mesurée de notre code (`draw()`) prend 0,1 à 0,3 ms par image. Il faut mesurer sur votre Mac avec **Diagnostic…** (menu de la barre des menus), puis ajuster si besoin.

## Problèmes rencontrés et résolus
- Le Linux du conteneur ne peut pas compiler pour macOS. Contournement : CI GitHub Actions sur macOS, avec les résultats publiés sur la branche `ci-results`, car les journaux d'Actions ne sont pas lisibles depuis le conteneur.
- `rusage_info_v4` n'a pas de compteur d'énergie → passage à `rusage_info_v6`.
- Le rendu ne s'arrêtait jamais au repos : le maintien de crête descendait trop lentement. Il tombe maintenant 6× plus vite pendant le silence ; le repos est atteint en 2 à 3 s.
- Sur la VM, la minuterie fire ~46 fois/s au lieu de 100, donc la source démo ne produisait que 22 000 échantillons/s. Elle est maintenant cadencée sur l'horloge réelle.
- Visuel liquide trop anguleux, traînées en « pluie » → surface lissée (la largeur de lissage suit la fluidité), remplissage plus sombre, traînées diffusées latéralement.

## Ce qui reste / pistes
1. **Tester sur votre Mac avec le vrai Spotify** : permission, reconnexion, fond d'écran, menus.
2. Mesurer la consommation réelle avec **Diagnostic…**. Si elle dépasse 2 % : baisser le fond d'écran à 24 i/s, puis réduire la résolution de rendu à 0,4×.
3. Petit défaut visuel : un halo de traînée s'accumule dans le coin supérieur droit avec le bruit rose (bord de la texture de traînée).
4. Pas d'icône d'app dessinée (icône système par défaut).
5. Lecture du titre : elle dépend de la notification de Spotify. Si une version future la supprime, le titre ne s'affichera plus, mais la capture continuera de marcher.
