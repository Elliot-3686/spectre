# Décisions techniques

Chaque écart par rapport au brief, et pourquoi. Critères : (1) consommation minimale, (2) précision maximale, (3) direction artistique « liquide sombre ».

## Environnement de développement
- **Développé dans un conteneur Linux, compilé sur un Mac virtuel GitHub Actions** (macOS 15, Apple M1 virtuel, Xcode 16.4). Je n'avais pas accès au Mac de l'utilisateur. La CI compile, lance les tests et produit les captures, le banc d'essai et une mesure CPU de l'app réelle en mode démo. Les résultats sont publiés sur la branche `ci-results` et l'app compilée dans la release `latest`.
- Conséquence : la capture réelle de Spotify et la consommation sur le Mac de l'utilisateur ne peuvent pas être vérifiées par la CI. Le menu **Diagnostic…** produit le rapport équivalent sur la vraie machine.
- **XcodeGen** (`project.yml`) génère le `.xcodeproj` au lieu de le versionner : fichier lisible, pas de conflits.

## Capture
- **Process tap Core Audio** (`CATapDescription(monoMixdownOfProcesses:)`) sur tous les processus dont le bundle ID commence par `com.spotify.client` (l'app et ses helpers), avec `muteBehavior = .unmuted` : le son entendu n'est ni modifié ni retardé.
  - Le **mixage mono est fait par le HAL** (mono mixdown) plutôt que L+R en logiciel : moins de données à copier pour un résultat identique.
  - L'API est marquée macOS 14.2 dans le SDK (le brief disait 14.4). On l'active dès 14.2.
  - **ScreenCaptureKit** sert de secours en dessous de 14.2, avec un filtre sur l'app Spotify.
- **Fréquence d'échantillonnage native** lue sur le format du tap, sans rééchantillonnage. Le format Float32 suffit (le bruit de quantification reste sous −140 dB), avec les accumulations en Double là où ça compte.
- **Zéro scrutation (polling)** :
  - lancement et arrêt de Spotify : NSWorkspace ;
  - lecture et pause : la notification distribuée `com.spotify.client.PlaybackStateChanged`, qui donne aussi le titre ;
  - changements de processus audio, de sortie par défaut et `IsRunningOutput` : écouteurs Core Audio.
- Quand Spotify est en pause, le tap et l'agrégat sont **détruits** : plus aucun callback audio.
- Permission : l'état est lu via TCC, chargé dynamiquement comme dans les outils d'exemple d'Apple. S'il est refusé, l'app affiche un message en français avec des boutons « Ouvrir les Réglages » et « Réessayer ».

## Temps réel
- Le callback du HAL écrit dans une **file circulaire sans verrou en C11** (stdatomic). Il ne prend aucun verrou, ne fait aucune allocation et n'utilise aucun objet Objective-C. Il ne réveille le thread d'analyse (sémaphore) qu'une fois par « hop », pas à chaque callback.
- Le thread d'analyse est dédié (QoS userInteractive). Tous ses tampons sont pré-alloués (`FloatBuffer`) : aucune allocation dans la boucle.

## Analyse (priorité précision)
- **Multi-résolution, proche d'une transformée à Q constant** : 32768 points sous 300 Hz, 8192 entre 300 Hz et 2,5 kHz, 2048 au-dessus. Les résolutions sont fondues en dB sur ±¼ d'octave autour des fréquences de coupure.
- **Chevauchement** : le hop vaut fréquence d'échantillonnage ÷ images/s (800 échantillons à 60 i/s), soit 97,5 % de chevauchement pour la fenêtre de 32768 points. Le « 50 % » du brief ne donnerait que 11 analyses par seconde avec 8192 points, trop peu pour un rendu fluide.
- **Estimation des pics** :
  1. interpolation parabolique sur le log du spectre ;
  2. affinage par **vocodeur de phase** entre deux trames séparées d'exactement un hop ;
  3. levée d'ambiguïté de phase en prenant le repliement le plus proche de l'estimation parabolique ;
  4. retour à la parabole si l'écart dépasse 0,3 bin.
- **Amplitude exacte des pics quelle que soit la fenêtre** : on divise par la réponse de la fenêtre au décalage fractionnaire. Cette réponse est tabulée numériquement à l'initialisation. La fenêtre flat-top n'est donc plus nécessaire pour avoir des dB exacts sur les pics. Elle reste proposée pour la courbe elle-même. Hann est la fenêtre par défaut ; Blackman-Harris et flat-top sont au choix.
- **Calibrage mesuré, pas supposé** : le facteur d'échelle de vDSP et le sens de la phase sont mesurés au démarrage (impulsion et sinusoïde décalée). Aucune convention d'Accelerate n'est codée en dur.
- **dBFS** : un sinus pleine échelle vaut 0 dBFS. Les bandes de tiers d'octave sont des sommes d'énergie divisées par la bande passante équivalente de bruit (ENBW), avec recouvrement fractionnaire des bins.
- **Crête vraie** en option : interpolation polyphase ×4.
- **Économie** : seuls les bins réellement utilisés sont convertis en dB. Quand la plus longue fenêtre ne contient que du silence, **aucune FFT** n'est calculée.

## Rendu (priorité énergie)
- **Pas de minuterie d'affichage permanente.** Les images sont déclenchées par l'arrivée de nouvelles données d'analyse. Quand l'audio s'arrête, du silence numérique traverse la chaîne normale pour que la matière retombe naturellement. Une minuterie coalescée (tolérance 15 %) ne tourne que pendant cette retombée. Ensuite il y a **0 image et 0 FFT**.
- Le repos est détecté par une **lecture en retour du GPU** sans blocage : énergie de la simulation en atomic max, nombre de grains en mouvement, lus dans le handler de fin d'exécution.
- **Images/s** : 60 en fenêtre, 30 en fond d'écran, 20 en économie. Le tout tombe à 0 quand c'est en pause, silencieux, verrouillé, en veille, sous l'économiseur d'écran ou caché (occlusion de la fenêtre, par exemple par une app plein écran).
- **Résolution du rendu** en fond d'écran : 0,5× sur Retina en Moyen et Économie, 0,75× en Haut. La matière est douce et le tramage cache l'agrandissement, ce qui divise par 4 le coût des fragments. Le texte reste net (SwiftUI à la résolution native).
- **Simulation sur GPU** dans un seul groupe de threads : ressorts amortis couplés par une équation d'onde 1D, avec sous-pas. Les graves sont lourds et visqueux, les aigus légers et vifs.
- **Traînées** : texture ping-pong à ½ résolution en Haut et ¼ en Moyen ; coupées en Économie.
- **Dégradés** : couleurs interpolées en OKLab via une table de 256 entrées. Le tramage triangulaire est appliqué **dans l'espace sRGB**, puis la cible `bgra8Unorm_srgb` ré-encode exactement : aucune marche visible dans les sombres.

## Interface
- App de la barre des menus (LSUIElement). Elle passe en mode « regular » (Dock, ⌘-Tab) seulement quand une fenêtre est ouverte.
- Les valeurs affichées (Hz, note, dB, pics, lecture au survol) viennent **toujours** de la FFT brute. Le curseur Fluidité ne touche que le visuel.
- Les textes sont rafraîchis 8 fois par seconde au maximum, pas 60 : SwiftUI coûte du CPU.
