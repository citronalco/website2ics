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

#use Data::Dumper;
use warnings;

my $url="https://www.ingolstadt.de/Kultur/Veranstaltungen/Veranstaltungskalender";

my $formatter=HTML::FormatText->new(leftmargin=>0, rightmargin=>1000);

my $mech=WWW::Mechanize->new();
my $hs=HTML::Strip->new();


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

    $mech->get($eventLink);

    my $eTree=HTML::TreeBuilder->new_from_content($mech->content);
    my $eventDetails=$eTree->look_down('_tag'=>'div','id'=>'event-details');

    $event->{'title'}=$eventDetails->find_by_tag_name('h1')->as_trimmed_text();
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
	#time_zone => "Europe/Berlin"
    );

    $event->{'ende'}=$event->{'beginn'}->clone();

    $event->{'ende'}->set_year("20".$endYear) if defined($endYear);
    $event->{'ende'}->set_month($endMonth) if defined($endMonth);
    $event->{'ende'}->set_day($endDay) if defined($endDay);
    $event->{'ende'}->set_hour($endHour) if defined($endHour);
    $event->{'ende'}->set_minute($endMinute) if defined($endMinute);

    # If no end date is given and event crosses midnight, add a day to end time
    unless (defined($endDay) and defined($endMonth) and defined($endYear)) {
	if (DateTime->compare($event->{'beginn'},$event->{'ende'}) eq 1) {
	    $event->{'ende'}->add(days=>1);
	}
    }

    # if a start time is given but no end time, assume the event takes 2 hours
    if (defined($startHour) and not defined($endHour)) {
	$event->{'ende'}->add(hours=>2);
    }

    # If no start time is given, it's a full-day event
    if (not defined($startHour)) {
	$event->{'fullday'}=1;
    }

    # Ort
    my @o=split(/\s*\n/, $details->look_down('_tag'=>'h3',sub{$_[0]->as_trimmed_text()=~/^Veranstaltungsort$/})->parent()->format($formatter));
    shift(@o);	# first element is string "Veranstaltungsort"
    $event->{'ort'}=join(", ",@o);

    # Veranstalter
    my @v=split(/\s*\n/, $details->look_down('_tag'=>'h3',sub{$_[0]->as_trimmed_text()=~/^Veranstalter$/})->parent()->format($formatter));
    shift(@v);	# first element is string "Veranstalter"
    $event->{'veranstalter'}=join(", ",@v);

    # Beschreibung
    my @b;
    try {
	my $text=$eventDetails->look_down('_tag'=>'div','id'=>'event-description')->format($formatter);
	$text=~s/^\s*Beschreibung\s*//;
	$text=~s/^[\\n\-\s]*//;
	$text=~s/\\n\\n+/\n/g;
	push(@b,$text);
    };
    try {
	my @li=$eventDetails->look_down('_tag'=>'div','id'=>'event-additional')->look_down('_tag'=>'li');
	push(@b,map { $_->format($formatter) } @li);
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

    my $eventEntry=Data::ICal::Entry::Event->new();
    $eventEntry->add_properties(
	uid=>$uid,
	summary => $event->{'title'},
	description => join("\n",$event->{'subtitle'},$event->{'description'}),
	dtstamp=>$dstamp,
	class=>"PUBLIC",
	#organizer=>"CN: ".$event->{'veranstalter'}//"",
	organizer=>"MAILTO:foobar",
	location=>$event->{'ort'},
#	categories=>$event->{'kategorien'}//"",
	categories=>$event->{'typ'},
	url=>$event->{'link'},
    );

    if (defined($event->{'fullday'})) {
	$eventEntry->add_properties(
	    dtstart=>[$event->{'beginn'}->ymd(''), {VALUE=>'DATE'}],
	    dtend=>[$event->{'ende'}->ymd(''), {VALUE=>'DATE'}],
	);
    }
    else {
	$eventEntry->add_properties(
	    dtstart=>DateTime::Format::ICal->format_datetime($event->{'beginn'}),
	    dtend=>DateTime::Format::ICal->format_datetime($event->{'ende'}),
	);
    }

    $calendar->add_entry($eventEntry);
    $count++;
}
die("Keine Einträge") if ($count==0);

print $calendar->as_string;
