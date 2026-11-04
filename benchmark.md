# Banc d'essai Spectre

Machine : Version 15.8.2 (Build 24H232), 3 cœurs

## Analyse (CPU, 1 cœur)

| Profil | FFT | i/s | µs / trame | % d'un cœur |
|---|---|---|---|---|
| Haut (fenêtre) | 32768/8192/2048 | 60 | 85.3 | 0.51 % |
| Moyen (fond d'écran) | 16384/4096 | 30 | 55.8 | 0.17 % |
| Économie | 4096 | 20 | 34.2 | 0.07 % |

## Rendu (GPU : Apple Paravirtual device)

| Mode | Contexte | Pixels | GPU ms / image | i/s | Occupation GPU | CPU encodage µs |
|---|---|---|---|---|---|---|
| Liquide | Fenêtre, Haut | 2240×1280 | 5.67 | 60 | 34.0 % | 5972 |
| Liquide | Fond d'écran, Moyen | 2560×1440 | 6.26 | 30 | 18.8 % | 6588 |
| Liquide | Fond d'écran, Économie | 1728×1117 | 3.43 | 20 | 6.9 % | 4106 |
| Sable | Fenêtre, Haut | 2240×1280 | 6.17 | 60 | 37.0 % | 7345 |
| Sable | Fond d'écran, Moyen | 2560×1440 | 6.12 | 30 | 18.4 % | 6411 |
| Sable | Fond d'écran, Économie | 1728×1117 | 3.53 | 20 | 7.1 % | 3928 |
| Courbe | Fenêtre, Haut | 2240×1280 | 3.42 | 60 | 20.5 % | 3724 |
| Courbe | Fond d'écran, Moyen | 2560×1440 | 4.10 | 30 | 12.3 % | 4372 |
| Courbe | Fond d'écran, Économie | 1728×1117 | 2.53 | 20 | 5.1 % | 2801 |
| Tiers d'octave | Fenêtre, Haut | 2240×1280 | 2.43 | 60 | 14.6 % | 2755 |
| Tiers d'octave | Fond d'écran, Moyen | 2560×1440 | 2.84 | 30 | 8.5 % | 3107 |
| Tiers d'octave | Fond d'écran, Économie | 1728×1117 | 1.78 | 20 | 3.6 % | 1989 |
| Spectrogramme | Fenêtre, Haut | 2240×1280 | 2.23 | 60 | 13.4 % | 2483 |
| Spectrogramme | Fond d'écran, Moyen | 2560×1440 | 2.62 | 30 | 7.9 % | 2873 |
| Spectrogramme | Fond d'écran, Économie | 1728×1117 | 1.95 | 20 | 3.9 % | 2447 |

CPU encodage = temps mur de `draw()` y compris l'attente GPU (borne haute).
