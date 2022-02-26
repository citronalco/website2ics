website2ics
===========

Perl command line scripts to automatically scrape event information from several web sites and build nice ics calendar files from it.

License
-------
This project is licensed under the terms of the GPLv3 License.

Supported web sites
-------------------
### Eventhalle Westpark, Ingolstadt
Source: http://www.eventhalle-westpark.de/das-programm

Script: `eventhalleWestpark2ics.pl`

Demo: https://www.geierb.de/~geierb/kalender/eventhallewestpark.ics


### Kulturzentrum Halle Neun, Ingolstadt
Source: http://halle9-ingolstadt.de

Script: `halle92ics.pl`

Demo: https://www.geierb.de/~geierb/kalender/halle9.ics


### Zündfunk Veranstaltungstipps
Source: http://www.br.de/radio/bayern2/sendungen/zuendfunk/veranstaltungen-praesentationen/index.html

Script: `zuendfunk2ics.pl`

Demo: https://www.geierb.de/~geierb/kalender/zuendfunk-tipps.ics


### KAP94, Ingolstadt
Source: http://www.kap94.de/events/month/

Script: `kap942ics.pl`

Demo: https://www.geierb.de/~geierb/kalender/kap94.ics


### Stadt Ingolstadt
Source: https://www.ingolstadt.de/Kultur/Veranstaltungen/Veranstaltungskalender/

Script: `stadtIngolstadt.pl`

Demo: https://www.geierb.de/~geierb/kalender/stadt-ingolstadt.ics


Usage
-----
Each of the scripts fetches events from a different web site and outputs the ics data on STDOUT, so you might want to pipe the output to a file.

Example:
```bash
$ perl kap942ics.pl > calendarfile.ics
````

Additional Web sites
===========
**Freilichtkino im Turm Baur** uses Wordpress with the All-in-One Event Calendar plugin. Though they hide the plugin's ics export button, the function is still available. Simply use https://www.freilichtkino-turm-baur.de/?plugin=all-in-one-event-calendar&controller=ai1ec_exporter_controller&action=export_events&no_html=true for subscriptions.
