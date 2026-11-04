# Banc d'essai Spectre

Machine : Version 15.8.2 (Build 24H232), 3 cœurs

## Analyse (CPU, 1 cœur)

| Profil | FFT | i/s | µs / trame | % d'un cœur |
|---|---|---|---|---|
| Haut (fenêtre) | 32768/8192/2048 | 60 | 89.1 | 0.53 % |
| Moyen (fond d'écran) | 16384/4096 | 30 | 59.4 | 0.18 % |
| Économie | 4096 | 20 | 35.1 | 0.07 % |

## Rendu (GPU : Apple Paravirtual device)

| Mode | Contexte | Pixels | GPU ms / image | i/s | Occupation GPU | CPU encodage µs |
|---|---|---|---|---|---|---|
| Liquide | Fenêtre, Haut | 2240×1280 | 5.50 | 60 | 33.0 % | 5905 |
| Liquide | Fond d'écran, Moyen | 2560×1440 | 6.16 | 30 | 18.5 % | 6435 |
| Liquide | Fond d'écran, Économie | 1728×1117 | 3.11 | 20 | 6.2 % | 3334 |
| Sable | Fenêtre, Haut | 2240×1280 | 5.49 | 60 | 32.9 % | 6200 |
| Sable | Fond d'écran, Moyen | 2560×1440 | 6.14 | 30 | 18.4 % | 6424 |
| Sable | Fond d'écran, Économie | 1728×1117 | 3.64 | 20 | 7.3 % | 4091 |
| Courbe | Fenêtre, Haut | 2240×1280 | 3.80 | 60 | 22.8 % | 4101 |
| Courbe | Fond d'écran, Moyen | 2560×1440 | 4.24 | 30 | 12.7 % | 4520 |
| Courbe | Fond d'écran, Économie | 1728×1117 | 3.15 | 20 | 6.3 % | 3463 |
| Tiers d'octave | Fenêtre, Haut | 2240×1280 | 2.53 | 60 | 15.2 % | 2779 |
| Tiers d'octave | Fond d'écran, Moyen | 2560×1440 | 2.81 | 30 | 8.4 % | 3076 |
| Tiers d'octave | Fond d'écran, Économie | 1728×1117 | 2.32 | 20 | 4.6 % | 2566 |
| Spectrogramme | Fenêtre, Haut | 2240×1280 | 2.49 | 60 | 14.9 % | 2756 |
| Spectrogramme | Fond d'écran, Moyen | 2560×1440 | 2.69 | 30 | 8.1 % | 3344 |
| Spectrogramme | Fond d'écran, Économie | 1728×1117 | 1.86 | 20 | 3.7 % | 2737 |

CPU encodage = temps mur de `draw()` y compris l'attente GPU (borne haute).
