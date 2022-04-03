#!/usr/bin/perl
# 2018 geierb@geierb.de
# CC-BY-SA

use strict;
use WWW::Mechanize;
use HTML::Strip;
use HTML::TreeBuilder;
use HTML::FormatText;

use DateTime::Format::Strptime;
use DateTime::Format::ICal;
use Data::ICal;
use Data::ICal::Entry::Event;
use Time::HiRes;

use Try::Tiny;

use utf8;
use open qw(:std :utf8);

use Data::Dumper;
use warnings;

my @events;

my $mech=WWW::Mechanize->new();
my $hs=HTML::Strip->new();


my $url="https://www.ingolstadt.de/Kultur/Veranstaltungen/Veranstaltungskalender";

my @eventList;
my $currentPage=0;

sub gotoNextPage {
    my @forms=$mech->forms;
    for (my $i=0;$i<scalar(@forms);$i++) {
	my $nextPage=$currentPage+1;
	if ($forms[$i]->{'action'}=~/page=$nextPage\D/) {
	    $mech->submit_form(form_number=>$i);
	    $currentPage=$nextPage;
	    return 1;
	}
    }
    return 0;
}

$mech->get($url);

# FIXME: limit is not working, everything gets fetched
my $dt=DateTime->now();
$mech->submit_form(with_fields=>{
    'filter[0][value][dateFormat]'=>$dt->dmy("."),
    'filter[0][secondValue][dateFormat]'=>$dt->add(months=>6)->dmy("."),
});

my %links;
do {
    my $tree=HTML::TreeBuilder->new_from_content($mech->content);
    foreach my $tr ($tree->look_down('_tag'=>'tr','onclick'=>qr/^window.location.*action=show/)) {
	my ($eventUrl)=$tr->attr('onclick')=~/^window.location=\'(.+?)\'/;
	$links{$url."/".$eventUrl}{'typ'}=$tr->look_down('_tag'=>'td')->right()->look_down('_tag'=>'span')->as_trimmed_text();
    }
} while (gotoNextPage());

foreach my $eventLink (keys (%links)) {
    my $event;
    $event->{'typ'}=$links{$eventLink}{'typ'};
    $event->{'fullday'}=0;

    $mech->get($eventLink);

    my $eTree=HTML::TreeBuilder->new_from_content($mech->content);
    my $eventDetails=$eTree->look_down('_tag'=>'div','id'=>'event-details');

    $event->{'title'}=$eventDetails->find_by_tag_name('h1')->as_text();
    $event->{'subtitle'}=$eventDetails->look_down('_tag'=>'div','class'=>'first-subtitle')->as_trimmed_text().$eventDetails->look_down('_tag'=>'div','class'=>'second-subtitle')->as_trimmed_text();

    my $details=$eTree->look_down('_tag'=>'div','id'=>'top-info');
    my $dateTime=$details->look_down('_tag'=>'h3',sub{$_[0]->as_trimmed_text()=~/^Datum und Uhrzeit$/})->right();
    my ($startDay,$startMonth,$startYear,
	$startHour,$startMinute,
	$endDay,$endMonth,$endYear,
	$endHour,$endMinute)=
	    $dateTime=~/^\s*(\d{2})\.(\d{2})\.\d*(\d{2})\s?(?:(\d{2}):(\d{2})(?::\d{2})?)?\s?(?:\p{Pd})?\s?(?:(\d{2})\.(\d{2})\.\d*(\d{2}))?\s?(?:(\d{2}):(\d{2})(?::\d{2})?)?\s*$/;

    $event->{'beginn'}=DateTime->new(
	day => $startDay,
	month => $startMonth,
	year => "20".$startYear,
	hour => $startHour // 0,
	minute => $startMinute // 0,
	time_zone => "Europe/Berlin"
    );

    if (($endDay) and ($endMonth) and ($endYear)) {
	$event->{'ende'}=DateTime->new(
	    day => $endDay,
	    month => $endMonth,
	    year => "20".$endYear,
	    hour => $endHour // 0,
	    minute => $endMinute // 0,
	    time_zone => "Europe/Berlin"
	);
    }
    else {
	# If no end date is given assume the events at the same day as it starts
	$event->{'ende'}=$event->{'beginn'}->clone();
    }

    # If a end time is given use it
    if (defined($endHour)) {
	$event->{'ende'}->set_hour($endHour);
	$event->{'ende'}->set_minute($endMinute);
    }
    # else if a start time is given but no end time, assume the event takes 2 hours
    elsif (defined($startHour)) {
	$event->{'ende'}->add(hours=>2);
    }
    # If no times are given it's a full-day event
    else {
	$event->{'fullday'}=1;
    }
    # If event crosses midnight add a day to ende
    if (DateTime->compare($event->{'beginn'},$event->{'ende'}) eq 1) {
	$event->{'ende'}->add(days=>1);
    }

    # Ort
    my @o=split(/\s*\n/,
	HTML::FormatText->new(lm=>0)->format_from_string(
	    $details->look_down('_tag'=>'h3',sub{$_[0]->as_trimmed_text()=~/^Veranstaltungsort$/})->parent()->as_HTML()
	)
    );
    shift(@o);	# first element is string "Veranstaltungsort"
    $event->{'ort'}=join(", ",@o);

    # Veranstalter
    my @v=split(/\s*\n/,
	HTML::FormatText->new(lm=>0)->format_from_string(
	    $details->look_down('_tag'=>'h3',sub{$_[0]->as_trimmed_text()=~/^Veranstalter$/})->parent()->as_HTML()
	)
    );
    shift(@v);	# first element is string "Veranstalter"
    $event->{'veranstalter'}=join(", ",@v);

    # Beschreibung
    my @b;
    try {
	my $text=$eventDetails->look_down('_tag'=>'div','id'=>'event-description')->as_trimmed_text();
	$text=~s/^\s*Beschreibung\s*//;
	push(@b,$text);
    };
    try {
	my @li=$eventDetails->look_down('_tag'=>'div','id'=>'event-additional')->look_down('_tag'=>'li');
	push(@b,map { $_->as_trimmed_text() } @li);
    };
    $event->{'description'}=join("\n\n",@b);

    # Kategorien
    try {
	($event->{'kategorien'})=
	    $eventDetails->look_down('_tag'=>'div','id'=>'event-additional')->look_down('_tag'=>'b',sub{$_[0]->as_trimmed_text()=~/^Kategorien:$/})->parent()->as_trimmed_text()=~/^Kategorien: (.*)$/;
    };

    # Link
    try {
	$event->{'link'}=
	    $eventDetails->look_down('_tag'=>'div','id'=>'event-additional')->look_down('_tag'=>'a')->attr('href');
    };
    push(@eventList,$event);
}


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
        "X-WR-CALNAME"=>"Stadt Ingolstadt",
        "X-WR-CALDESC"=>"Veranstaltungskalender der Stadt Ingolstadt");

my $count=0;
foreach my $event (@eventList) {
    # Create uid
    my @tm=localtime();
    my $uid=sprintf("%d%02d%02d%02d%02d%02d%s%02d\@geierb.de",
	$tm[5] + 1900, $tm[4] + 1, $tm[3], $tm[2],
	$tm[1], $tm[0], scalar(Time::HiRes::gettimeofday()), $count);

    my ($startTime,$endTime);

    if ($event->{'fullday'}) {
	$startTime=sprintf("%04d%02d%02d",$event->{'beginn'}->year,$event->{'beginn'}->month,$event->{'beginn'}->day);
	$endTime=sprintf("%04d%02d%02d",$event->{'ende'}->year,$event->{'ende'}->month,$event->{'ende'}->day),
    }
    else {
	$startTime=DateTime::Format::ICal->format_datetime(
	    DateTime->new(
		year=>$event->{'beginn'}->year,
		month=>$event->{'beginn'}->month,
		day=>$event->{'beginn'}->day,
		hour=>$event->{'beginn'}->hour,
		minute=>$event->{'beginn'}->min,
		second=>0,
		#time_zone=>'Europe/Berlin'
	    )
	);

	$endTime=DateTime::Format::ICal->format_datetime(
	    DateTime->new(
		year=>$event->{'ende'}->year,
		month=>$event->{'ende'}->month,
		day=>$event->{'ende'}->day,
		hour=>$event->{'ende'}->hour,
		minute=>$event->{'ende'}->min,
		second=>0,
		#time_zone=>'Europe/Berlin'
	    )
	);
    }

    my $eventEntry=Data::ICal::Entry::Event->new();
    $eventEntry->add_properties(
	uid=>$uid,
	summary => $event->{'title'},
	description => join("\n",$event->{'subtitle'},$event->{'description'}),
	dtstart=>$startTime,
	dtend=>$endTime,
	dtstamp=>$dstamp,
	class=>"PUBLIC",
	#organizer=>"CN: ".$event->{'veranstalter'}//"",
	organizer=>"MAILTO:foobar",
	location=>$event->{'ort'},
#	categories=>$event->{'kategorien'}//"",
	categories=>$event->{'typ'},
	url=>$event->{'link'},
    );

    $calendar->add_entry($eventEntry);
    $count++;
}
die("Keine Einträge") if ($count==0);

print $calendar->as_string;
