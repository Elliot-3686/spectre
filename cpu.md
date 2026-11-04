# Consommation mesurée (app complète, mode démo)

| Phase | CPU process | Images/s | Réveils/s | Énergie (W, estimée par macOS) |
|---|---|---|---|---|
| Fenêtre (60 i/s) + fond d'écran (30 i/s), musique | 9.99 % | 60.7 — audio 47992 éch/s, analyses 59.4/s, pertes 0 ; fenêtre 37.8 i/s (0.43 ms/draw) fond 22.9 i/s (0.20 ms/draw) | 46 | 0.000 |
| Fond d'écran seul (30 i/s), musique | 5.33 % | 20.7 — audio 47929 éch/s, analyses 30.0/s, pertes 0 ; fenêtre 0.0 i/s (0.00 ms/draw) fond 20.7 i/s (0.18 ms/draw) | 42 | 0.000 |
| Spotify absent / en pause (repos) | 0.06 % | 0.2 — audio 0 éch/s, analyses 0.0/s, pertes 0 ; fenêtre 0.0 i/s (0.00 ms/draw) fond 0.2 i/s (0.15 ms/draw) | 1 | 0.000 |

Analyse : FFT 16384/4096 · 48000 Hz · 30 i/s · Moyen · coût moyen 50 µs/trame
