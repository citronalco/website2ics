#!/usr/bin/perl
# 2022 geierb@geierb.de
# GPLv3

use strict;
use WWW::Mechanize;
use HTML::Entities;
use HTML::TreeBuilder;

use DateTime::Format::Strptime;
use DateTime::Format::ICal;
use Data::ICal;
use Data::ICal::Entry::Event;
use Time::HiRes;

use Try::Tiny;
use List::MoreUtils qw(first_index);

use utf8;
use Data::Dumper;
use warnings;


my $url="https://backstage.eu/veranstaltungen.html";
my $defaultDauer=119;   # angenommene Dauer eines Events in Minuten (steht nicht im Programm, wird aber für Kalendereintrag gebraucht)
my @months=("januar", "februar", "märz", "april", "mai", "juni", "juli", "august", "september", "oktober", "november", "dezember");


my $datumFormat=DateTime::Format::Strptime->new('pattern'=>'%d.%m.%Y %H:%M','time_zone'=>'Europe/Berlin');
binmode STDOUT, ":utf8";	# Gegen "wide character"-Warnungen

my $mech=WWW::Mechanize->new();

my @eventList;

my $pageNo=1;
my $success;

do {
    $success=0;
    $mech->get($url."?p=".$pageNo++) or die($!);
    foreach my $eventLink ($mech->find_all_links(class=>'product-item-link')) {
	my $event;

	# URL
	$event->{'url'}=$eventLink->url_abs()->as_string;
	#print $event->{'url'}."\n";

	# Bereits vorhandene überspringen
	my $found=0;
	foreach my $e (@eventList) {
	    if ($e->{'url'} eq $event->{'url'}) {
		$found=1;
		last;
	    }
	}
	next if $found==1;

	# Event-Seite laden
	my $ok=eval { $mech->get($eventLink); }; # sometimes some links are broken
	next unless ($ok);

	my $root=HTML::TreeBuilder->new_from_content($mech->content());

	# Kurzbeschreibung
	$event->{'kurzbeschreibung'}=$root->look_down('_tag'=>'meta','property'=>'og:description')->attr('content');

	my $info=$root->look_down('_tag'=>'div','class'=>'product-info-main');
	# Kategorie
	$event->{'kategorie'}=$info->look_down('_tag'=>'a','class'=>'ox-product-page__category-link')->as_trimmed_text;

	my $innerInfo=$info->look_down('_tag'=>'div','class'=>'page-title-wrapper product');
	# Titel
	$event->{'titel'}=$innerInfo->look_down('_tag'=>'h1','class'=>'page-title')->as_trimmed_text;
	$event->{'titel'}=~s/([\w'’]+)/\u\L$1/g;

	# Untertitel
	try {
	    $event->{'titel'}.=" - ".$innerInfo->look_down('_tag'=>'h1','class'=>'page-title')->right()->as_trimmed_text;
	};

	my $essentialInfo=$info->look_down('_tag'=>'div','class'=>'product-info-essential');
	# Preis und Link zu Tickets
	try {
	    my $link=$event->{'ticketUrl'}=$mech->find_link('url'=>'#bstickets');
	    $event->{'preis'}=$link->text();
	    $event->{'tickets'}=$link->url_abs()->as_string;
	};

	# Ort
	$event->{'ort'}=$essentialInfo->look_down('_tag'=>'div','class'=>'product attribute eventlocation')->look_down('_tag'=>'div','class'=>'value')->as_trimmed_text;

	# Veranstalter
	$event->{'veranstalter'}=$essentialInfo->look_down('_tag'=>'div','class'=>'product attribute eventpresenter')->look_down('_tag'=>'div','class'=>'value')->as_trimmed_text;

	# Datum und Zeit
	my $datumzeit;
	try {
	    $datumzeit=$essentialInfo->look_down('_tag'=>'strong','class'=>'type',
		sub {
		    $_[0]->as_text=~/^Veranstaltungsdatum/
		}
	    )->right()->as_trimmed_text;
	};
	next unless($datumzeit); # Ohne Datum kein Kalendereintrag möglich!

	my ($day,$monthname,$year,$beginnHH,$beginnMM,$einlassHH,$einlassMM)=$datumzeit=~/\w+ (\d{1,2})\. (\w+) (\d{4})Beginn(\d{1,2})[:\.](\d{2}) UhrEinlass(\d{1,2})[:\.](\d{2}) Uhr/;
	# Monatsname nach Monatsnummer
	my $month=1+first_index { $_ eq lc($monthname) } @months;
	$event->{'einlass'}=$datumFormat->parse_datetime($day.".".$month.".".$year." ".$einlassHH.":".$einlassMM);
	$event->{'beginn'}=$datumFormat->parse_datetime($day.".".$month.".".$year." ".$beginnHH.":".$beginnMM);

	$event->{'ende'}=$event->{'beginn'}->clone();
	$event->{'ende'}->add(minutes=>$defaultDauer);


	# Beschreibung
	try {
	    $event->{'beschreibung'}=$info->look_down('_tag'=>'div','id'=>'description')->as_trimmed_text;
	};

	$success=1;
	push(@eventList,$event);
    }
}
while ($success);


# Create Datestamp for dtstamp
my @stamp=localtime;
my $dstamp = sprintf("%d%02d%02dT%02d%02d%02dZ",
    $stamp[5] + 1900,
    $stamp[4] + 1,
    $stamp[3],
    $stamp[2],
    $stamp[1],
    $stamp[0]);

my $calendar=Data::ICal->new();
$calendar->add_properties(method=>"PUBLISH",
        "X-PUBLISHED-TTL"=>"P1D",
        "X-WR-CALNAME"=>"Backstage",
        "X-WR-CALDESC"=>"Veranstaltungen Backstage");

my $count=0;
foreach my $event (@eventList) {
    # Create uid
    my @tm=localtime();
    my $uid=sprintf("%d%02d%02d%02d%02d%02d%s%02d\@geierb.de",
                    $tm[5] + 1900, $tm[4] + 1, $tm[3], $tm[2],
                    $tm[1], $tm[0], scalar(Time::HiRes::gettimeofday()), $count);

    my $description;
    if ($event->{'kurzbeschreibung'})
	{ $description.=$event->{'kurzbeschreibung'}." \n\n"; }
    if ($event->{'preis'})
	{ $description.=$event->{'preis'}." \n"; }
    if ($event->{'tickets'})
	{ $description.=$event->{'tickets'}." \n"; }
    if ($event->{'einlass'})
	{ $description.="Einlass: ".sprintf("%02d:%02d Uhr",$event->{'einlass'}->hour,$event->{'einlass'}->minute)." \n"; }

    if ($event->{'beschreibung'})
	{ $description.=" \n".$event->{'beschreibung'}." \n\n"; }


    if ($event->{'veranstalter'}) {
	$description.="Veranstalter: ".$event->{'veranstalter'};
    }

    my $eventEntry=Data::ICal::Entry::Event->new();
    $eventEntry->add_properties(
	uid=>$uid,
	summary => $event->{'titel'},
	description => $description,
	categories => $event->{'kategorie'},
	dtstart => DateTime::Format::ICal->format_datetime(
	    DateTime->new(
		year=>$event->{'beginn'}->year,
		month=>$event->{'beginn'}->month,
		day=>$event->{'beginn'}->day,
		hour=>$event->{'beginn'}->hour,
		minute=>$event->{'beginn'}->min,
		second=>0,
		#time_zone=>'Europe/Berlin'
	    )
	),
	dtend => DateTime::Format::ICal->format_datetime(
	    DateTime->new(
		year=>$event->{'ende'}->year,
		month=>$event->{'ende'}->month,
		day=>$event->{'ende'}->day,
		hour=>$event->{'ende'}->hour,
		minute=>$event->{'ende'}->min,
		second=>0,
		#time_zone=>'Europe/Berlin'
	    )
	),
	dtstamp=>$dstamp,
	class=>"PUBLIC",
	organizer=>"MAILTO:foobar",
	location=>$event->{'ort'},
	url=>$event->{'url'},
    );

    $calendar->add_entry($eventEntry);
    $count++;
}
die("Keine Einträge") if ($count==0);

print $calendar->as_string;
