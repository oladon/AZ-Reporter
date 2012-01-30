#!/usr/bin/perl

use strict;
use warnings;
use DateTime;
use JSON;
use LWP::UserAgent;
use Tie::Hash::Indexed;
use Data::Dumper;

my $json_data;
my @included_phases;
my @included_statuses;
my @included_steps;
my %phases;
my %reports;
my %statuses;
my %steps;
my %stories;
my %storydata;
my %tag_groups;

tie %phases, 'Tie::Hash::Indexed';
tie %statuses, 'Tie::Hash::Indexed';
tie %steps, 'Tie::Hash::Indexed';
tie %tag_groups, 'Tie::Hash::Indexed';

### User configuration ###
my $apikey = "";     # Fill in your API key
my $projectid = "";     # Fill in your story's numeric id
my $url = "https://agilezen.com/api/v1/projects/$projectid/stories/?apikey=$apikey&with=everything";
my $outputdir = "/path/to/your/output/directory/";     # Leave empty for current directory
my %ignored_phases = ("Backlog" => 1,
                      "Archive" => 1);
my %ignored_statuses = ();
my %ignored_steps = ("backlog" => 1,
                     "archive" => 1);
%reports = ("averages" => {"clusters" => \@included_phases,
                           "stacks" => \@included_steps,
                           "colors" => "'green', 'blue'",
                           "haxis_title" => "",
                           "indata" => "averages",
                           "title" => "Average Time per Phase",
                           "vaxis_title" => "Days",
                           "code" => \&averages_report},
            "counts" => {"clusters" => \@included_phases,
                         "stacks" => \@included_statuses,
                         "colors" => "'red', 'black', 'grey', 'green', 'blue'",
                         "haxis_title" => "",
                         "indata" => "counts",
                         "title" => "Counts per Phase",
                         "vaxis_title" => "Count",
                         "code" => \&counts_report},
            "throughput" => {"clusters" => ["all", '10', '12', '1'],
                             "stacks" => {"count" => ["count"],
                                          "phase" => \@included_phases,
                                          "step" => ["block", "wait", "work"]},
                             "colors" => "'black', 'dimgrey', 'slategrey', 'steelblue', 'royalblue', 'red', 'green', 'blue'",
                             "haxis_title" => "Month Finished",
                             "indata" => "throughput",
                             "title" => "Average Throughput by Month Finished",
                             "vaxis_title" => "Days",
                             "tags" => 0,
                             "code" => \&throughput_report});
%tag_groups = ("all" => {"reports" => {"counts" => 1,
                                       "throughput" => 1},
                         "tags" => ["all"]},
               "standard" => {"reports" => {"averages" => 1},
                              "tags" => ["bug", "feature"]},
               "nonstandard" => {"reports" => {"averages" => 1},
                                 "tags" => ["request"]},
               "custom" => {"reports" => {"averages" => 1},
                            "tags" => ["custom"]});
### END User configuration ###

my $ua = LWP::UserAgent->new;
my $result = $ua->get($url);

if ($result->is_success) {
  $json_data = $result->{_content};
  my %decoded = %{decode_json($json_data)};

  # Go through stories & create hash of refs
  for my $i (0..$#{$decoded{items}}) {
    my $storyref = \%{$decoded{items}[$i]};
    $stories{$$storyref{id}} = $storyref;

    $statuses{$$storyref{status}}++;
    push(@{$storydata{by_status}{$$storyref{status}}}, $storyref);

    # Go through milestones (phase changes)
    for my $j (0..$#{$$storyref{milestones}}) {
      my $mileref = \%{$$storyref{milestones}[$j]};

      if (!defined $$mileref{endTime}) {
        $$mileref{endTime} = sprintf("%s", DateTime->now);;
      }

      $phases{$$mileref{phase}{name}}++;

      # Go through steps (status changes), find any that match
      for my $k (0..$#{$$storyref{steps}}) {
        my $stepref = \%{$$storyref{steps}[$k]};

        if (!defined $$stepref{endTime}) {
          $$stepref{endTime} = sprintf("%s", DateTime->now);;
        }

        if (!defined $$mileref{phase}{name} || !defined $$stepref{type}) {
          die "Something is null!";
        }

        $steps{$$stepref{type}}++;      # Keep a list/count of steps

        my $time = get_overlap($$mileref{startTime}, $$mileref{endTime}, $$stepref{startTime}, $$stepref{endTime});
        if ((defined $time) && ($time > 0)) {
          $stories{$$storyref{id}}{total_times}{$$mileref{phase}{name}}{$$stepref{type}} += round($time / 86400);
        } else {
          $stories{$$storyref{id}}{total_times}{$$mileref{phase}{name}}{$$stepref{type}} += 0;
        }
      }
    }

    # Go through tags & count
    my @temp_tags_list; # Keep a list of tags, append them only if "custom" isn't present.
    for my $l (0..$#{$$storyref{tags}}) {
      my $tagname = $$storyref{tags}[$l]{name};
      push(@temp_tags_list, $tagname);
      if ($tagname eq "custom") {
        @temp_tags_list = ('custom');
        last;
      }
    }
    for my $tag (@temp_tags_list) {
      push(@{$storydata{by_tag}{$tag}}, $storyref);
      push(@{$storydata{counts}{$tag}{$$storyref{phase}{name}}{$$storyref{status}}}, $$storyref{id});  # Count this card under tag/phase/status
    }

  }

  @included_phases = get_left(\%phases, \%ignored_phases);
  @included_statuses = get_left(\%statuses, \%ignored_statuses);
  @included_steps = get_left(\%steps, \%ignored_steps);

  ## Average all times together
  my %tempdata;
  for my $story (values %stories) {
#    print Dumper $$story{total_times} if $$story{status} eq "finished";
    for my $phase (keys %{$$story{total_times}}) {
      next if defined $ignored_phases{$phase};
      for my $step (keys %{$$story{total_times}{$phase}}) {
        next if defined $ignored_steps{$step};
        $tempdata{totals}{all}{$phase}{$step} += $$story{total_times}{$phase}{$step};
        $tempdata{counts}{all}{$phase}{$step}++;
        $storydata{averages}{all}{$phase}{$step} = $tempdata{totals}{all}{$phase}{$step} / $tempdata{counts}{all}{$phase}{$step};
      }
    }
  }

  %tempdata = ();
  for my $tag (keys %{$storydata{by_tag}}) {
    for my $story (@{$storydata{by_tag}{$tag}}) {
      for my $phase (keys %{$$story{total_times}}) {
        next if defined $ignored_phases{$phase};
        for my $step (keys %{$$story{total_times}{$phase}}) {
          next if defined $ignored_steps{$step};
          $tempdata{totals}{$tag}{$phase}{$step} += $$story{total_times}{$phase}{$step};
          $tempdata{counts}{$tag}{$phase}{$step}++;
          $storydata{averages}{$tag}{$phase}{$step} = $tempdata{totals}{$tag}{$phase}{$step} / $tempdata{counts}{$tag}{$phase}{$step};
        }
      }
    }
  }
  undef %tempdata;
  # End gathering average times per phase

  # Gather data about total throughput times
  for my $card (@{$storydata{by_status}{finished}}) {
    my $month = DateTime->from_epoch(epoch => parse_to_epoch($$card{metrics}{finishTime}))->month();
    my $alltimes = \%{$storydata{throughput}{all}};
    my $monthtimes = \%{$storydata{throughput}{$month}};

    # Get times by phase
    for my $phase (keys %{$$card{total_times}}) {
      next if defined $ignored_phases{$phase};
      for my $step (keys %{$$card{total_times}{$phase}}) {
        next if defined $ignored_steps{$step};
        $$alltimes{phase}{$phase} += $$card{total_times}{$phase}{$step};
        $$monthtimes{phase}{$phase} += $$card{total_times}{$phase}{$step};
      }
    }

    # Get times by step
    my $blockedTime = \$$card{metrics}{blockedTime};
    my $waitTime = \$$card{metrics}{waitTime};
    my $workTime = \$$card{metrics}{workTime};

    $$alltimes{step}{block} += $$blockedTime;
    $$alltimes{step}{wait} += $$waitTime;
    $$alltimes{step}{work} += $$workTime;
    $$monthtimes{step}{block} += $$blockedTime;
    $$monthtimes{step}{wait} += $$waitTime;
    $$monthtimes{step}{work} += $$workTime;

    $storydata{throughput}{all}{count}{count}++;
    $storydata{throughput}{$month}{count}{count}++;

  }
  # End gathering data about throughput times


  ## Loop through all reports
  for my $report (keys %reports) {
    my $subref = $reports{$report}{code};
    my $inputref = $storydata{$reports{$report}{indata}};
    my %results = &{$subref}($reports{$report}, $inputref);

    for my $group (keys %tag_groups) {
      next if !defined $tag_groups{$group}{reports}{$report};

      if (defined $reports{$report}{tags} && $reports{$report}{tags} == 0) {
        $group = 0;
      }

      ## Produce the output
      my $chart_result = make_chart($report, $group, \%results);
      unless ($chart_result == 1) {
        warn "Failed to create chart file for $report, $group: $chart_result\n";
      }
    }
  }

} else {
  die $result->status_line;
}

sub averages_report {
  my ($self, $inref) = @_;
  my $phasesref = $$self{clusters};
  my $stepsref = $$self{stacks};
  my %time_per_phase;

  ## Aggregate the averages and re-format to be usable
  for my $phase (@{$phasesref}) {
    for my $tag (keys %{$inref}) {
      for my $step (sort @{$stepsref}) {
        $$inref{$tag}{$phase}{$step} = 0 if !defined $$inref{$tag}{$phase}{$step};
        push(@{$time_per_phase{$phase}{$tag}}, $$inref{$tag}{$phase}{$step});
      }
    }
  }

  return %time_per_phase;
}

sub counts_report {
  my ($self, $inref) = @_;
  my $phasesref = $$self{clusters};
  my $statusref = $$self{stacks};
  my %all_counts;

  # Aggregate the counts and re-format to be usable
  for my $phase (@{$phasesref}) {
    my %counted_stories = ();
    my %temp_total_counts = ();
    for my $status (sort @{$statusref}) {
      for my $tag (keys %{$inref}) {
        if (defined $$inref{$tag} && defined $$inref{$tag}{$phase}{$status}) {
          for my $story_id (@{$$inref{$tag}{$phase}{$status}}) {
            if (!defined $counted_stories{$story_id}) {
              $temp_total_counts{$status}++;
              $counted_stories{$story_id}++;
            }
          }
        } else {
          $temp_total_counts{$status} += 0;
        }
      }
      push(@{$all_counts{$phase}{all}}, $temp_total_counts{$status});
    }
  }

  return %all_counts;
}

sub throughput_report {     # Get the average throughput times by all and month
  my ($self, $inref) = @_;
  my $phasesref = $$self{clusters};
  my $stepsref = $$self{stacks};
  my @line;
  my %avg_throughputs = ();

  # Period here is a month number or "all"
  for my $period (sort keys %$inref) {
    for my $stackname (sort keys %{$stepsref}) {
      for my $stackitem (@{$$stepsref{$stackname}}) {
        @line = ();
        for my $testname (sort keys %{$$inref{$period}}) {
          for my $testitem (sort keys %{$$inref{$period}{$testname}}) {
            if ($stackname eq $testname) {
              if ($testname eq "count") {
                push(@line, $$inref{$period}{$testname}{$testitem});
              } else {
                push(@line, round($$inref{$period}{$testname}{$testitem} / $$inref{$period}{count}{count}));
              }
            } else {
              push(@line, "null");
            }
          }
        }
      }
      push(@{$avg_throughputs{$period}}, [@line]);
    }
  }
  return %avg_throughputs;

}

sub date_diff {
  my ($datestring1, $datestring2) = @_;

  my $dt1 = parse_to_epoch($datestring1);
  my $dt2 = parse_to_epoch($datestring2);

  if (defined $dt1 && defined $dt2) {
    return $dt1 - $dt2;
  } else {
    return -1;
  }

}

sub generate_addcolumn {
  my ($chartname, $type, $name) = @_;

  return "    ${chartname}_data.addColumn('$type', '$name');\n";
}

sub generate_addrow {
  my ($chartname, $tag, $dataref) = @_;
  $tag = "\"$tag\"" if $tag ne "null";

  return "    ${chartname}_data.addRow([$tag, " . join(", ", @{$dataref}) . "]);\n";
}

sub generate_google_viz {
  my ($report, $group, $dataref) = @_;
  my $chartname = $report . "_" . $group;
  my $grouping = "";
  my $js_code = "";
  my $phasesref = $reports{$report}{clusters};
  my $stepsref = $reports{$report}{stacks};
  my $title = $reports{$report}{title};
  $grouping = " by Tag ($group)" if $group ne "0";

  my $js_header = "google.load(\"visualization\", \"1\", {packages:[\"corechart\"]});
  google.setOnLoadCallback(drawChart_$chartname);
  function drawChart_$chartname() {
    var ${chartname}_data = new google.visualization.DataTable();\n";

  my $js_footer = "    var ${chartname}_chart = new google.visualization.ColumnChart(document.getElementById('${chartname}_visualization'));
    ${chartname}_chart.draw(${chartname}_data, {
                    title: '$title$grouping',
                    width: 800, height: 600,\n";
  if (defined $tag_groups{$group} && defined $tag_groups{$group}{colors}) {
    $js_footer .= "                    colors: [" . $tag_groups{$group}{colors} . "],\n";
  } elsif (defined $reports{$report}{colors}) {
    $js_footer .= "                    colors: [" . $reports{$report}{colors} . "],\n";
  }
  $js_footer .= "                    hAxis: {
                      showTextEvery: 1,
                        slantedText: true,
                          title: \"$reports{$report}{haxis_title}\"
        },
                    isStacked: true,
                    vAxis: {
                      title: \"$reports{$report}{vaxis_title}\"
        }
    });
  }\n";

  $js_code .= $js_header;

  $js_code .= generate_addcolumn($chartname, "string", "Tag");
  # Is the chart to be clustered with different values?
  if (ref($stepsref) eq 'HASH') {
    for my $stepgroup (sort keys %{$stepsref}) {
      for my $step (@{$$stepsref{$stepgroup}}) {
        $js_code .= generate_addcolumn($chartname, "number", $step);
      }
    }
  } else {
    for my $step (@{$stepsref}) {
      $js_code .= generate_addcolumn($chartname, "number", $step);
    }
  }

  for my $phasenum (0..$#{$phasesref}) {
    my $phase = $$phasesref[$phasenum];

    if ($group ne "0") {
      for my $tag (sort @{$tag_groups{$group}{tags}}) {
        next if !defined $$dataref{$phase} or !defined $$dataref{$phase}{$tag}; # there's no data with the tag or phase
        $js_code .= generate_addrow($chartname, $tag, $$dataref{$phase}{$tag});
      }
    } else {
      for my $line (@{$$dataref{$phase}}) {
        $js_code .= generate_addrow($chartname, $phase, $line);
      }
    }

    if (ref($stepsref) eq 'HASH') {
      my @allsteps;
      for my $stepgroup (sort keys %{$stepsref}) {
        push(@allsteps, @{$$stepsref{$stepgroup}});
      }
      $js_code .= generate_addrow($chartname, 'null', [('null') x @allsteps]) if $phasenum < $#{$phasesref};
    } else {
      for my $step (@{$stepsref}) {
        $js_code .= generate_addrow($chartname, 'null', [('null') x @{$stepsref}]) if $phasenum < $#{$phasesref};
      }
    }
  }
  $js_code .= $js_footer;

  return $js_code;
}

sub get_left {
  my ($lref, $rref) = @_;
  my @result_array = ();

  for my $lkey (keys %{$lref}) {
    if (!defined $$rref{$lkey}) {
      push(@result_array, $lkey);
    }
  }

  return @result_array;
}

sub get_overlap {
  my ($start1, $end1, $start2, $end2) = @_;
  my ($dtst1, $dten1, $dtst2, $dten2);
  my $overlap;

  $dtst1 = parse_to_epoch($start1);
  $dten1 = parse_to_epoch($end1);
  $dtst2 = parse_to_epoch($start2);
  $dten2 = parse_to_epoch($end2);

  if (($dtst1 > $dten1) || ($dtst2 > $dten2)) {
    return undef;       # Error -- not a valid range
  }

  if ($dtst1 > $dtst2) {
    ($dtst1, $dtst2) = ($dtst2, $dtst1);
    ($dten1, $dten2) = ($dten2, $dten1);
  }

  if ($dtst2 >= $dten1) {
    return 0;   # no overlap
  }

  if ($dten1 > $dten2) {
    $overlap = $dten2 - $dtst2;
  } else {
    $overlap = $dten1 - $dtst2;
  }

  return $overlap;

}

sub make_chart {
  my ($report, $group, $inref) = @_;
  my $outfile = $outputdir . $report . "_" . $group . ".js";

  open my $OUT, ">$outfile" or return $!;
  print $OUT generate_google_viz($report, $group, $inref);
  close $OUT or return $!;
  return 1;

}

sub new_dt {
  return DateTime->new(
                       year => $_[0],
                       month => $_[1],
                       day => $_[2],
                       hour => $_[3],
                       minute => $_[4],
                       second => $_[5],
                       time_zone => "UTC");
}

sub parse_to_epoch {
  my ($string) = @_;

  my @fields = ($string =~ /(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/);

  my $dt = new_dt(@fields) if @fields;

  if (defined $dt) {
    return $dt->epoch;
  } else {
    return -1;
  }

}

sub round {
  my ($num, $digits) = @_;

  $digits = 2 if !defined $digits;

  my $format = "%." . $digits . "f";

  return sprintf($format, $num);
}

sub test_get_overlap {
  print get_overlap("2011-08-03T16:13:14", "2011-08-03T16:13:34", "2011-08-01T22:42:51", "2011-08-03T16:13:14") . "\n";
  print "Right answer: 0\n";

  print get_overlap("2011-08-03T16:13:14", "2011-08-03T16:13:34", "2011-08-01T22:42:51", "2011-08-03T16:13:24") . "\n";
  print "Right answer: 10\n";

  print get_overlap("2011-08-03T16:13:14", "2011-08-03T16:13:34", "2011-08-03T16:13:19", "2011-08-03T16:13:24") . "\n";
  print "Right answer: 5\n";

  print get_overlap("2011-08-03T16:13:14", "2011-08-03T16:13:34", "2011-08-03T16:13:19", "2011-08-03T16:13:44") . "\n";
  print "Right answer: 15\n";

  print get_overlap("2011-08-03T16:13:14", "2011-08-03T16:13:34", "2011-08-03T16:13:09", "2011-08-03T16:13:44") . "\n";
  print "Right answer: 20\n";
}
