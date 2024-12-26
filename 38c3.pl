#!/usr/bin/perl
# 2024 geierb@geierb.de
# AGPLv3

use strict;
use warnings;
use utf8;

use WWW::Mechanize;
use JSON;
use DateTime::Format::Strptime;
use DateTime::Format::ICal;
use Data::ICal;
use Data::ICal::Entry::Event;
use Data::ICal::Entry::TimeZone;
use Data::ICal::Entry::TimeZone::Daylight;
use Data::ICal::Entry::TimeZone::Standard;

binmode STDOUT, ":utf8";

my $url="https://api.events.ccc.de/congress/2024/schedule.json";
my @mainStages = ('Saal 1', 'Saal GLITCH', 'Saal ZIGZAG', 'Stage HUFF', 'Stage YELL');

# Function: convert datetime to DTSTART/DTEND property value
sub dt2icaldt {
    my ($dt)=@_;
    my $icalformatdt=DateTime::Format::ICal->format_datetime($dt);
    if (my ($id,$string)=$icalformatdt=~/^TZID=(.+?):(.+)$/) {
        return [ $string, {TZID => $id} ];
    }
    else {
        return $icalformatdt;
    }
}

# Create Datestamp for dtstamp
my @stamp=localtime;
my $dtstamp = sprintf("%d%02d%02dT%02d%02d%02dZ",
    $stamp[5] + 1900,
    $stamp[4] + 1,
    $stamp[3],
    $stamp[2],
    $stamp[1],
    $stamp[0]);


# Download schedule.json
my $mech=WWW::Mechanize->new();
$mech->get($url) or die($!);

# Parse JSON
my $data = JSON::decode_json($mech->content());

# Create ICS
my $calendar = Data::ICal->new(auto_uid=>1);

my $calendarName = $data->{'schedule'}->{'conference'}->{'title'};
if (defined($ARGV[0])) {
    if ($ARGV[0] eq "main") {
	$calendarName .= " - Main Stages";
    }
    elsif ($ARGV[0] eq "notmain") {
	$calendarName .= " - Side Stages";
    }
}

$calendar->add_properties(
    method=>"PUBLISH",
    "X-PUBLISHED-TTL" => "PT10M",	# 10 minutes refresh interval
    "X-WR-CALNAME" => $calendarName,
    "X-WR-CALDESC" => $data->{'schedule'}->{'conference'}->{'url'},
);

# Add VTIMEZONE
my $tz=$data->{'schedule'}->{'conference'}->{'time_zone_name'};
my $vtimezone=Data::ICal::Entry::TimeZone->new();
$vtimezone->add_properties(tzid=>$tz);

my $tzDaylight=Data::ICal::Entry::TimeZone::Daylight->new();
$tzDaylight->add_properties(
    tzoffsetfrom => "+0100",
    tzoffsetto  => "+0200",
    dtstart     => "19700329T020000",
    tzname      => "CEST",
    rrule       => "FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU"
);
$vtimezone->add_entry($tzDaylight);

my $tzStandard=Data::ICal::Entry::TimeZone::Standard->new();
$tzStandard->add_properties(
    tzoffsetfrom => "+0200",
    tzoffsetto  => "+0100",
    dtstart     => "19701025T030000",
    tzname      => "CET",
    rrule       => "FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU"
);
$vtimezone->add_entry($tzStandard);

$calendar->add_entry($vtimezone);


my $dateTimeParser = DateTime::Format::Strptime->new(
    pattern => '%Y-%m-%dT%H:%M:%S%z',	# 2024-12-28T06:00:00+01:00
    time_zone => 'Europe/Berlin',
    on_error => 'croak',
);

# Loop through days
foreach my $day (@{$data->{'schedule'}->{'conference'}->{'days'}}) {
    # Loop through rooms
    foreach my $roomName (keys %{$day->{'rooms'}}) {
	my $roomData = $day->{'rooms'}->{$roomName};
	# Loop through events in this room
	foreach my $event (@{$roomData}) {
	    # Get speakers
	    my @personNames;
	    foreach my $person (@{$event->{'persons'}}) {
		push(@personNames, $person->{'name'});
	    }

	    # Map event info to ics attributes
	    my $e;
	    $e->{'uid'} = $event->{'guid'};

	    # Summary, with persons, language and not-recorded flag
	    $e->{'summary'} = $event->{'title'};

	    if (@personNames) {
		$e->{'summary'} .= " - ".join(", ", @personNames);
	    }
	    if ($event->{'language'}) {
		$e->{'summary'} .= " [".$event->{'language'}."]";
	    }
	    if ($event->{'do_not_record'}) {
		$e->{'summary'} .= " [NOT RECORDED]";
	    }

	    # Start and end
	    my $start = $event->{'date'}=~s/^(.+):(\d{2})$/$1$2/r;	# make start date ISO 8601 conform (remove colon from time zone)
	    $e->{'dtstart'} = $dateTimeParser->parse_datetime($start);
	    $e->{'dtend'} = $e->{'dtstart'}->clone();
	    $event->{'duration'}=~/(\d{2}):(\d{2})/;
	    $e->{'dtend'}->add(hours=>$1, minutes=>$2); 

	    # Other
	    $e->{'location'} = $event->{'room'};
	    $e->{'url'} = $event->{'url'};
	    $e->{'categories'} = join(", ", grep {defined} ($event->{'track'} , $event->{'type'}));
	    $e->{'description'} = join("\n", grep {defined} ($event->{'abstract'}, $event->{'description'}));


	    # Add event entry to calendar
	    # ...unless user wants only a subset
	    if (defined($ARGV[0])) {
		if ($ARGV[0] eq "main") {
		    next unless grep(/^$e->{'location'}$/i, @mainStages);
		}
		elsif ($ARGV[0] eq "notmain") {
		    next if grep(/^$e->{'location'}$/i, @mainStages);
		}
	    }

	    my $eventEntry = Data::ICal::Entry::Event->new();
	    $eventEntry->add_properties(
		class => 'PUBLIC',
		uid => $e->{'uid'},
		summary => $e->{'summary'},
		dtstart => dt2icaldt($e->{'dtstart'}),
		dtend => dt2icaldt($e->{'dtend'}),
		location => $e->{'location'},
		url => $e->{'url'},
		categories => $e->{'categories'},
		description => $e->{'description'},
		dtstamp => $dtstamp,
	    );

	    # Add event to calendar
	    $calendar->add_entry($eventEntry);
	}
    }
};

print $calendar->as_string;
