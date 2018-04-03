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

### Intro.de
Source: http://www.intro.de

Script: `intro2ics.pl`

Demo: http://www.geierb.de/~geierb/kalender/intro.ics

### Zündfunk Veranstaltungstipps
Source: http://www.br.de/radio/bayern2/sendungen/zuendfunk/veranstaltungen-praesentationen/index.html

Script: `zuendfunk2ics.pl`

Demo: https://geierb.de/~geierb/kalender/zuendfunk-tipps.ics


### KAP94, Ingolstadt
Source: http://www.kap94.de/events/month/

Script: `kap942ics.pl`

Demo: https://geierb.de/~geierb/kalender/kap94.ics


Usage
-----
Each of the scripts fetches events from a different web site and outputs the ics data on STDOUT, so you might want to pipe the output to a file.

Example:
```bash
$ perl website2ics.pl > calendarfile.ics
````

The only script that supports **and requires** command line arguments is `intro2ics.pl`. You have to give at least one city name for which events should be fetched.
Example:
```bash
$ perl intro2ics.pl hamburg berlin muenchen > calendarfile.ics
````

