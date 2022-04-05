# website2ics
Veranstaltungsorte haben meist hübsche Webseiten und Social-Media-Auftritte, auf denen sie Konzerte, Shows und andere Veranstaltungen ankündigen.

Leider schaffen es die meisten nicht, einen ics/ical-Kalender anzubieten, den man bequem am Telefon oder in Outlook, Thunderbird oder Nextcloud abonnieren kann.

Um keine (oder weniger) Termine zu verpassen habe ich einige Skripte geschrieben, die Webseiten von Veranstaltungsorten abgrasen, die Programminformationen auslesen und als ics-Datei ausgeben.

## Unterstützte Veranstaltungsorte
| Veranstaltungsort | Datenquelle | Skript | Demo-Kalender (ical) |
|--|--|--|--|
| Bayern (Zündfunk Veranstaltungstipps) | https://www.br.de/radio/bayern2/sendungen/zuendfunk/veranstaltungen-praesentationen/index.html | `bayern-zuendfunk.pl` | https://www.geierb.de/~geierb/kalender/zuendfunk-tipps.ics |
| Ingolstadt, Eventhalle Westpark | https://www.eventhalle-westpark.de/das-programm | `ingolstadt-eventhalleWestpark.pl`| https://www.geierb.de/~geierb/kalender/eventhallewestpark.ics |
| Ingolstadt, Kulturzentrum neun | https://www.neun-ingolstadt.de/programm/ | `ingolstadt-halle9.pl` | https://www.geierb.de/~geierb/kalender/halle9.ics |
| Ingolstadt, KAP94 | https://kap94.de/events/ | `ingolstadt-kap94.pl` | https://www.geierb.de/~geierb/kalender/kap94.ics |
| Ingolstadt (Stadt) | https://www.ingolstadt.de/Kultur/Veranstaltungen/Veranstaltungskalender | `ingolstadt-stadtIngolstadt.pl` | https://www.geierb.de/~geierb/kalender/stadt-ingolstadt.ics |
| München, Backstage | https://backstage.eu/veranstaltungen.html | `muenchen-backstage.pl` | https://www.geierb.de/~geierb/kalender/backstage.ics |
| München, Milla | https://www.milla-club.de/category/event/ | `muenchen-milla.pl` | https://www.geierb.de/~geierb/kalender/milla.ics |
| München, Muffatwerk (mit Club Ampere) | https://www.muffatwerk.de/de/events | `muenchen-muffatwerk.pl` | https://www.geierb.de/~geierb/kalender/muffatwerk.ics |
| München, Strom | https://strom-muc.de/ | `muenchen-strom.pl`  | https://www.geierb.de/~geierb/kalender/strom.ics |
| Nürnberg, Hirsch | https://www.der-hirsch.com/programm.html | `nuernberg-hirsch.pl` | https://www.geierb.de/~geierb/kalender/hirsch.ics |
| Nürnberg, Z-Bau | https://z-bau.com/programm/ | `nuernberg-z-bau.pl` | https://www.geierb.de/~geierb/kalender/z-bau.ics |

Die Demo-Kalender werden täglich aktualisiert und können abonniert werden.

## Verwendung
Beispiel:
`perl nuernberg-z-bau.pl > z-bau.ics`

So richtig nützlich wird's erst, wenn man die Skripte automatisch regelmäßig per Cron ausführt und die erzeugten ics-Dateien auf einen Webserver legt.

## Lizenz
Dieses Projekt ist lizenziert unter der GPLv3.

## Weitere Webseiten
Das **Freilichtkino im Turm Baur** (Ingolstadt) hat eine Wordpress-Webseite und verwendet das "All-in-One Event Calendar"-Plugin. Dieses Plugin kann ics-Dateien ausgeben, das Freilichtkino hat nur den Knopf dazu ausgeblendet. Zum Abonnieren des Kalenders diese URL benutzen: [https://www.freilichtkino-turm-baur.de/?plugin=all-in-one-event-calendar&controller=ai1ec_exporter_controller&action=export_events&no_html=true](https://www.freilichtkino-turm-baur.de/?plugin=all-in-one-event-calendar&controller=ai1ec_exporter_controller&action=export_events&no_html=true)

Die **Eventfabrik München** (Tonhalle, Knödelplatz,...) hat auf ihrer Webseite (https://www.eventfabrik-muenchen.de/events/) einen Link zum Kalender-Abonnieren ("ical download"). Sehr gut!

