# Consommation mesurée (app complète, mode démo)

| Phase | CPU process | Images/s | Réveils/s | Énergie (W, estimée par macOS) |
|---|---|---|---|---|
| Fenêtre (60 i/s) + fond d'écran (30 i/s), musique | 11.40 % | 59.1 — audio 47993 éch/s, analyses 59.1/s, pertes 0 ; fenêtre 36.7 i/s (0.21 ms/draw) fond 22.5 i/s (0.07 ms/draw) | 47 | 0.000 |
| Fond d'écran seul (30 i/s), musique | 7.89 % | 20.8 — audio 47989 éch/s, analyses 29.9/s, pertes 0 ; fenêtre 0.0 i/s (0.00 ms/draw) fond 20.8 i/s (0.18 ms/draw) | 42 | 0.000 |
| Spotify absent / en pause (repos) | 0.11 % | 1.2 — audio 0 éch/s, analyses 0.0/s, pertes 0 ; fenêtre 0.0 i/s (0.00 ms/draw) fond 1.2 i/s (0.18 ms/draw) | 2 | 0.000 |

Analyse : FFT 16384/4096 · 48000 Hz · 30 i/s · Moyen · coût moyen 61 µs/trame
