#################################################################
# $Id: 88_Timer.pm 15699 2019-09-12 21:17:50Z HomeAuto_User $
#
# The module is a timer for executing actions.
# 2019 - HomeAuto_User & elektron-bbs
#################################################################

package main;

use strict;
use warnings;
use Time::HiRes qw(gettimeofday);

use Data::Dumper qw (Dumper);

my @action = ("on","off","*");
#my @names = ("Timer","Year","Month","Day","Hour","Minute","Second","Device or Perl","Aktion","Mon","Tue","Wed","Thur","Fri","Sat","Sun","active","");
my @names = ("Nr.","Jahr","Monat","Tag","Stunde","Minute","Sekunde","Ger&auml;t oder Bezeichnung","Aktion","Mo","Di","Mi","Do","Fr","Sa","So","aktiv","");
my $cnt_attr_userattr = 0;

##########################
sub Timer_Initialize($) {
	my ($hash) = @_;

	$hash->{AttrFn}       = "Timer_Attr";
	$hash->{AttrList}     = "disable:0,1 Show_DeviceInfo:alias,comment Simulation_only:on,off Timer_preselection:on,off Border_Cell:on,off Border_Table:on,off $readingFnAttributes ";
	$hash->{DefFn}        = "Timer_Define";
	$hash->{SetFn}        = "Timer_Set";
	$hash->{GetFn}        = "Timer_Get";
	$hash->{UndefFn}      = "Timer_Undef";
	$hash->{NotifyFn}     = "Timer_Notify";
	### Variante 1 ###
	#$hash->{FW_summaryFn} = "Timer_summaryFn";          # displays html instead of status icon in fhemweb room-view

	### Variante 2 ###
	$hash->{FW_detailFn}	= "Timer_FW_Detail";
	$hash->{FW_addDetailToSummary} = 1;
	$hash->{FW_deviceOverview} = 1;
}

##########################
# Predeclare Variables from other modules may be loaded later from fhem
our $FW_wname;

##########################
sub Timer_Define($$) {
	my ($hash, $def) = @_;
	my @arg = split("[ \t][ \t]*", $def);
	my $name = $arg[0];					## Der Definitionsname, mit dem das Gerät angelegt wurde.
	my $typ = $hash->{TYPE};		## Der Modulname, mit welchem die Definition angelegt wurde.
	my $filelogName = "FileLog_$name";
	my ($cmd, $ret);
	my ($autocreateFilelog, $autocreateHash, $autocreateName, $autocreateDeviceRoom, $autocreateWeblinkRoom) = ('./log/' . $name . '-%Y-%m.log', undef, 'autocreate', $typ, $typ);
	$hash->{NOTIFYDEV} = "global,TYPE=$typ";

	return "Usage: define <name> $name"  if(@arg != 2);

	if ($init_done) {
		if (!defined(AttrVal($autocreateName, "disable", undef)) && !exists($defs{$filelogName})) {
			# create FileLog
			$autocreateFilelog = $attr{$autocreateName}{filelog} if (exists $attr{$autocreateName}{filelog});
			$autocreateFilelog =~ s/%NAME/$name/g;
			$cmd = "$filelogName FileLog $autocreateFilelog $name";
			Log3 $filelogName, 2, "$name: define $cmd";
			$ret = CommandDefine(undef, $cmd);
			if($ret) {
				Log3 $filelogName, 2, "$name: ERROR: $ret";
			} else {
				### Attributes ###
				$attr{$filelogName}{room} = $autocreateDeviceRoom;
				$attr{$filelogName}{logtype} = 'text';
				$attr{$name}{room} = $autocreateDeviceRoom;
			}
		}

		### Attributes ###
		$attr{$name}{room} = "$typ" if (not exists($attr{$name}{room}) );				# set room, if only undef --> new def
	}

	### default value´s ###
	$hash->{STATE} = "Defined";
	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, "state" , "Defined");
	readingsBulkUpdate($hash, "internalTimer" , "stop");
	readingsEndUpdate($hash, 0);
	return undef;
}

#####################
sub Timer_Set($$$@) {
	my ( $hash, $name, @a ) = @_;
	return "no set value specified" if(int(@a) < 1);

	my $setList = "addTimer:noArg ";
	my $cmd = $a[0];
	my $cmd2 = $a[1];
	my $Timers_Count = 0;
	my $Timers_Count2;
	my $Timers_diff = 0;
	my $Timer_preselection = AttrVal($name,"Timer_preselection","off");
	my $value;

	foreach my $d (sort keys %{$hash->{READINGS}}) {
		if ($d =~ /^Timer_(\d)+$/) {
			$Timers_Count++;
			$d =~ s/Timer_//;
			$setList.= "deleteTimer:" if ($Timers_Count == 1);
			$setList.= $d.",";
		}
	}

	if ($Timers_Count != 0) {
		$setList = substr($setList, 0, -1);  # cut last ,
		$setList.= " saveTimers:noArg";
	}

	$setList.= " sortTimer:noArg" if ($Timers_Count > 1);

	Log3 $name, 4, "$name: Set | cmd=$cmd" if ($cmd ne "?");

	if ($cmd eq "sortTimer") {
		my @timers_unsortet;
		my $userattr_new = "";
		my @userattr_values;
		my $timer_nr_new;
		RemoveInternalTimer($hash, "Timer_Check");

		foreach my $readingsName (keys %{$hash->{READINGS}}) {
			if ($readingsName =~ /^Timer_(\d+)$/) {
				my $value = ReadingsVal($name, $readingsName, 0);
				$value =~ /^.*\d{2},(.*),(on|off|\*)/;
				push(@timers_unsortet,$1.",".ReadingsVal($name, $readingsName, 0).",$readingsName");	 # unsort Reading Wert in Array -> dfhdf,alle,alle,alle,alle,alle,00,dfhdf,*,1,1,1,1,1,1,1,0,Timer_14
				readingsDelete($hash, $readingsName);										          # Timer loeschen
			}
		}

		my @timers_sort = sort @timers_unsortet;                              # Timer in neues Array sortieren

		for (my $i=0; $i<scalar(@timers_sort); $i++) {
			$timer_nr_new = sprintf("%02s",$i + 1);                             # neue Timer-Nummer
			if ($timers_sort[$i] =~ /^.*\d{2},(.*),(\*),.*,(Timer_\d+)/) {      # filtre * values - Perl Code (* must in S2 - Timer nr old $3)
				if ($attr{$name}{$3."_set"}) {
					Log3 $name, 3, "in if ".$timers_sort[$i];				
					push(@userattr_values,"Timer_$timer_nr_new".",".AttrVal($name, $3."_set",0));  # userattr value in Array with new numbre
				}
				Timer_delFromUserattr($hash,$3."_set:textField-long");                           # delete from userattr (old numbre)
				addToDevAttrList($name,"Timer_$timer_nr_new"."_set:textField-long ");            # added to userattr (new numbre)
			}
			$timers_sort[$i] = substr( substr($timers_sort[$i],index($timers_sort[$i],",")+1) ,0,-9);
			readingsSingleUpdate($hash, "Timer_".$timer_nr_new , $timers_sort[$i], 1);
		}

		addStructChange("modify", $name, "attr $name userattr");              # note with question mark

		if (scalar(@userattr_values) > 0) {                                   # write userattr_values
			for (my $i=0; $i<scalar(@userattr_values); $i++) {
				my $timer_nr = substr($userattr_values[$i],0,8)."_set";
				my $value_attr = substr($userattr_values[$i],index($userattr_values[$i],",")+1);
				CommandAttr($hash,"$name $timer_nr $value_attr");
			}		
		}
		Timer_Check($hash);
	}

	if ($cmd eq "addTimer") {
		$Timers_Count = 0;
		foreach my $d (sort keys %{$hash->{READINGS}}) {
			if ($d =~ /^Timer_(\d+)$/) {
				$Timers_Count++;
				$Timers_Count2 = $1 * 1;
				if ($Timers_Count != $Timers_Count2 && $Timers_diff == 0) {  # only for diff
					$Timers_diff++;
					last;
				}
			}
		}

		if ($Timer_preselection eq "on") {
			my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
			$value = $year + 1900 .",".sprintf("%02s", ($mon + 1)).",".sprintf("%02s", $mday).",".sprintf("%02s", $hour).",".sprintf("%02s", $min).",00,,on,1,1,1,1,1,1,1,0";
		} else {
			$value = "alle,alle,alle,alle,alle,00,,on,1,1,1,1,1,1,1,0";
		}

		$Timers_Count = $Timers_Count + 1 if ($Timers_diff == 0);

		readingsSingleUpdate($hash, "Timer_".sprintf("%02s", $Timers_Count) , $value, 1);
	}

	if ($cmd eq "saveTimers") {
		open(SaveDoc, '>', "./FHEM/lib/$name"."_conf.txt") || return "ERROR: file $name"."_conf.txt can not open!";
			foreach my $d (sort keys %{$hash->{READINGS}}) {
				print SaveDoc $1.",".$hash->{READINGS}->{$d}->{VAL}."\n" if ($d =~ /^Timer_(\d+)$/);
			}
		close(SaveDoc);
	}

	if ($cmd eq "deleteTimer") {
		foreach my $d (sort keys %{$hash->{READINGS}}) {
			if ($d =~ /^Timer_$cmd2/) {
				readingsDelete($hash, $d);
				Log3 $name, 3, "$name: Set | $cmd $cmd2 -> with Reading ".$d;
			}
		}

		readingsBeginUpdate($hash);
		readingsBulkUpdate($hash, "state" , "Timer_$cmd2 deleted");
		readingsEndUpdate($hash, 1);

		if ($Timers_Count == 0) {
			readingsSingleUpdate($hash, "internalTimer" , "stop",1);
			RemoveInternalTimer($hash, "Timer_Check");
		}

		my $deleteTimer = "Timer_$cmd2"."_set:textField-long";
		Timer_delFromUserattr($hash,$deleteTimer);
		addStructChange("modify", $name, "attr $name userattr Timer_$cmd2");      # note with question mark
	}

	return $setList if ( $a[0] eq "?");
	return "Unknown argument $cmd, choose one of $setList" if (not grep /$cmd/, $setList);
	return undef;
}

#####################
sub Timer_Get($$$@) {
	my ( $hash, $name, $cmd, @a ) = @_;
	my $list = "loadTimers:no,yes";
	my $cmd2 = $a[0];

	if ($cmd eq "loadTimers") {
		if ($cmd2 eq "no") {
			return "";
		}

		if ($cmd2 eq "yes") {
			my $error = 0;
			my @lines;
			RemoveInternalTimer($hash, "Timer_Check");

			open (InputFile,"<./FHEM/lib/$name"."_conf.txt") || return "ERROR: No file $name"."_conf.txt found in ./FHEM/lib directory from FHEM!";
			while (<InputFile>){
				chomp ($_);                            # Zeilenende entfernen
				Log3 $name, 3, "$name: $_";
				push(@lines,$_);                       # lines in array
				my @values = split(",",$_);            # split line in array to check
				$error++ if (scalar(@values) != 17);
				for (my $i=0;$i<@values;$i++) {
					$error++ if ($i == 0 && $values[0] !~ /^\d{2}$/);
					$error++ if ($i == 1 && $values[1] !~ /^\d{4}$|^alle$/);
					if ($i >= 2 && $i <= 5 && $values[$i] ne "alle") {
						$error++ if ($i >= 2 && $i <= 3 && $values[$i] !~ /^\d{2}$/);
						$error++ if ($i == 2 && ($values[2] * 1) < 1 && ($values[2] * 1) > 12);
						$error++ if ($i == 3 && ($values[3] * 1) < 1 && ($values[3] * 1) > 31);

						if ($i >= 4 && $i <= 5 && $values[$i] ne "SA" && $values[$i] ne "SU") {
							$error++ if ($i >= 4 && $i <= 5 && $values[$i] !~ /^\d{2}$/);
							$error++ if ($i == 4 && ($values[4] * 1) > 23);
							$error++ if ($i == 5 && ($values[5] * 1) > 59);
						}
					}
					$error++ if ($i == 6 && $values[$i] % 10 != 0);
					$error++ if ($i == 8 && not grep { $values[$i] eq $_ } @action);
					$error++ if ($i >= 9 && $values[$i] ne "0" && $values[$i] ne "1");

					if ($error != 0) {
						close InputFile;
						return "ERROR: your file is NOT valid! ($error)";
					}
				}
			}
			close InputFile;

			foreach my $d (sort keys %{$hash->{READINGS}}) {
				readingsDelete($hash, $d) if ($d =~ /^Timer_(\d+)$/);
			}

			foreach my $e (@lines) {
				my $Timer_nr = substr($e,0,2);
				readingsSingleUpdate($hash, "Timer_$Timer_nr" , substr($e,3,length($e)-3), 1);
			}
			readingsSingleUpdate($hash, "state" , "Timers loaded", 1);
			FW_directNotify("FILTER=$name", "#FHEMWEB:WEB", "location.reload('true')", "");
			Timer_Check($hash);

			return undef;
		}
	}

	return "Unknown argument $cmd, choose one of $list";
}

#####################
sub Timer_Attr() {
	my ($cmd, $name, $attrName, $attrValue) = @_;
	my $hash = $defs{$name};
	my $typ = $hash->{TYPE};

	if ($cmd eq "set" && $init_done == 1 ) {
		Log3 $name, 3, "$name: Attr | set $attrName to $attrValue";
		if ($attrName eq "disable") {
			if ($attrValue eq "1") {
				readingsSingleUpdate($hash, "internalTimer" , "stop",1);
				RemoveInternalTimer($hash, "Timer_Check");
			} elsif ($attrValue eq "0") {
				Timer_Check($hash);
			}
		}
		
		if ($attrName =~ /^Timer_\d{2}_set$/) {
			my $err = perlSyntaxCheck($attrValue, ());   # check PERL Code
			return $err if($err);
		}
	}

	if ($cmd eq "del") {
		Log3 $name, 3, "$name: Attr | Attributes $attrName deleted";
		if ($attrName eq "disable") {
			Timer_Check($hash);
		}

		if ($attrName eq "userattr") {
			$cnt_attr_userattr++;
			return "Please execute again if you want to force the attribute to delete!" if ($cnt_attr_userattr == 1);
			$cnt_attr_userattr = 0;
		}
	}
}

#####################
sub Timer_Undef($$) {
	my ($hash, $arg) = @_;
	my $name = $hash->{NAME};

	RemoveInternalTimer($hash, "Timer_Check");
	Log3 $name, 4, "$name: Undef | device is delete";

	return undef;
}

#####################
sub Timer_Notify($$) {
	my ($hash, $dev_hash) = @_;
	my $name = $hash->{NAME};
	my $typ = $hash->{TYPE};
	return "" if(IsDisabled($name));	# Return without any further action if the module is disabled
	my $devName = $dev_hash->{NAME};	# Device that created the events
	my $events = deviceEvents($dev_hash, 1);

	if($devName eq "global" && grep(m/^INITIALIZED|REREADCFG$/, @{$events}) && $typ eq "Timer") {
		Log3 $name, 4, "$name: Notify is running and starting $name";
		Timer_Check($hash);
	}

	return undef;
}

##### HTML-Tabelle Timer-Liste erstellen #####
sub Timer_FW_Detail($$$$) {
	my ($FW_wname, $d, $room, $pageHash) = @_;		# pageHash is set for summaryFn.
	my $hash = $defs{$d};
	my $name = $hash->{NAME};
	my $html = "";
	my $selected = "";
	my $cnt_max = scalar(@names);
	my $Timers_Count = 0;
	my $Border_Table = AttrVal($name,"Border_Table","off");
	my $Border_Cell = AttrVal($name,"Border_Cell","off");
	my $border = "";
	my $time = FmtDateTime(time());
	my $FW_room_dupl = $FW_room;
	my @timer_nr;

	Log3 $name, 4, "$name: attr2html is running";

	foreach my $d (sort keys %{$hash->{READINGS}}) {
		if ($d =~ /^Timer_\d+$/) {
			$Timers_Count++;
			push(@timer_nr, substr($d,index($d,"_")+1));		
		}
	}
	$border = "border:2px solid #00FF00;" if($Border_Table eq "on");
	$html.= "<div id=\"table\"><table class=\"block wide\" cellspacing=\"0\" style=\"$border\">";

	#         Timer Jahr  Monat Tag   Stunde Minute Sekunde Gerät   Aktion Mo Di Mi Do Fr Sa So aktiv speichern
	#         -------------------------------------------------------------------------------------------------
	#               2019  09    03    18     15     00      Player  on     0  0  0  0  0  0  0  0
	# Spalte: 0     1     2     3     4      5      6       7       8      9  10 11 12 13 14 15 16    17
	#         -------------------------------------------------------------------------------------------------
	# T 1 id: 20    21    22    23    24     25     26      27      28     29 30 31 32 33 34 35 36    37         ($id = timer_nr * 20 + $Spalte)
	# T 2 id: 40    41    42    43    44     45     46      47      48     49 50 51 52 53 54 55 56    57         ($id = timer_nr * 20 + $Spalte)

	## Überschriften
	$html.= "<tr>";
	####
	$border = "border:1px solid #D8D8D8;" if($Border_Cell eq "on");
	my $background = "";
	for(my $spalte = 0; $spalte <= $cnt_max - 1; $spalte++) {
		$html.= "<td width=70 style=\"$border text-align:center; text-decoration:underline\">".$names[$spalte]."</td>" if ($spalte >= 1 && $spalte <= 6);   ## definierte Breite bei Auswahllisten
		$html.= "<td style=\"$border text-align:center; text-decoration:underline\">".$names[$spalte]."</td>" if ($spalte == 0 || ($spalte > 6 && $spalte <= $cnt_max));	## auto Breite
	}
	$html.= "</tr>";

	for(my $zeile = 0; $zeile < $Timers_Count; $zeile++) {
		$background = "background-color:#F0F0D8;" if ($zeile % 2 == 0);
		$background = "" if ($zeile % 2 != 0);
		$html.= "<tr>";
		my $id = $timer_nr[$zeile] * 20; # id 20, 40, 60 ...
		# Log3 $name, 3, "$name: Zeile $zeile, id $id, Start";

		my @select_Value = split(",", ReadingsVal($name, "Timer_".$timer_nr[$zeile], "alle,alle,alle,alle,alle,00,Lampe,on,0,0,0,0,0,0,0,0,,"));
		for(my $spalte = 1; $spalte <= $cnt_max; $spalte++) {
			$html.= "<td style=\"$border $background text-align:center\">".sprintf("%02s", $timer_nr[$zeile])."</td>" if ($spalte == 1);	# Spalte Timer-Nummer
			if ($spalte >=2 && $spalte <= 7) {	## DropDown-Listen fuer Jahr, Monat, Tag, Stunde, Minute, Sekunde
				my $start = 0;																# Stunde, Minute, Sekunde
				my $stop = 12;																# Monat
				my $step = 1;																	# Jahr, Monat, Tag, Stunde, Minute
				$start = substr($time,0,4) if ($spalte == 2);	# Jahr
				$stop = $start + 10 if ($spalte == 2);				# Jahr
				$start = 1 if ($spalte == 3 || $spalte == 4);	# Monat, Tag
				$stop = 31 if ($spalte == 4);									# Tag
				$stop = 23 if ($spalte == 5);									# Stunde
				$stop = 59 if ($spalte == 6);									# Minute
				$stop = 50 if ($spalte == 7);									# Sekunde
				$step = 10 if ($spalte == 7);									# Sekunde
				$id++;

				# Log3 $name, 3, "$name: Zeile $zeile, id $id, select";
				$html.= "<td style=\"$border $background text-align:center\"><select id=\"".$id."\">";	# id need for java script
				$html.= "<option>alle</option>" if ($spalte <= 6);				# Jahr, Monat, Tag, Stunde, Minute
				if ($spalte == 5 || $spalte == 6) {												# Stunde, Minute
					$selected = $select_Value[$spalte-2] eq "SA" ? "selected=\"selected\"" : "";
					$html.= "<option $selected value=\"SA\">SA</option>";		# Sonnenaufgang
					$selected = $select_Value[$spalte-2] eq "SU" ? "selected=\"selected\"" : "";
					$html.= "<option $selected value=\"SU\">SU</option>";		# Sonnenuntergang
				}
				for(my $k = $start ; $k <= $stop ; $k += $step) {
					$selected = $select_Value[$spalte-2] eq sprintf("%02s", $k) ? "selected=\"selected\"" : "";
					$html.= "<option $selected value=\"" . sprintf("%02s", $k) . "\">" . sprintf("%02s", $k) . "</option>";
				}
				$html.="</select></td>";
			}

			if ($spalte == 8) {			## Spalte Geraete
				$id ++;
				my $comment = "";
				$comment = AttrVal($select_Value[$spalte-2],"alias","") if (AttrVal($name,"Show_DeviceInfo","") eq "alias");
				$comment = AttrVal($select_Value[$spalte-2],"comment","") if (AttrVal($name,"Show_DeviceInfo","") eq "comment");
				$html.= "<td style=\"$border $background\"><input type=\"text\" id=\"".$id."\" value=\"".$select_Value[$spalte-2]."\"><br><small>$comment</small></td>";
			}

			if ($spalte == 9) {			## DropDown-Liste Aktion
				$id ++;
				$html.= "<td style=\"$border $background text-align:center\"><select id=\"".$id."\">";							# id need for java script
				foreach (@action) {
					$html.= "<option> $_ </option>" if ($select_Value[$spalte-2] ne $_);
					$html.= "<option selected=\"selected\">".$select_Value[$spalte-2]."</option>" if ($select_Value[$spalte-2] eq $_);
				}
				$html.="</select></td>";
			}

			## Spalte Wochentage + aktiv
			Log3 $name, 5, "$name: attr2html | Timer=".$timer_nr[$zeile]." ".$names[$spalte-1]."=".$select_Value[$spalte-2]." cnt_max=$cnt_max ($spalte)" if ($spalte > 1 && $spalte < $cnt_max);

			## existierender Timer
			if ($spalte > 9 && $spalte < $cnt_max) {
				$id ++;
				$html.= "<td style=\"$border $background text-align:center\"><input type=\"checkbox\" name=\"days\" id=\"".$id."\" value=\"0\" onclick=\"Checkbox(".$id.")\"></td>" if ($select_Value[$spalte-2] eq "0");
				$html.= "<td style=\"$border $background text-align:center\"><input type=\"checkbox\" name=\"days\" id=\"".$id."\" value=\"1\" onclick=\"Checkbox(".$id.")\" checked></td>" if ($select_Value[$spalte-2] eq "1");
			}
			## Button Speichern
			if ($spalte == $cnt_max) {
				$id ++;
				$html.= "<td style=\"$border $background text-align:center\"> <INPUT type=\"reset\" onclick=\"pushed_savebutton(".$id.")\" value=\"&#128190;\"/> </td>"; # &#128427; &#128190;
			}
		}
		$html.= "</tr>";			## Zeilenende
	}
	$html.= "</table>";			## Tabellenende

	## Tabellenende	+ Script
	$html.= '</div>

	<script>
	/* checkBox Werte von Checkboxen Wochentage */
	function Checkbox(id) {
		var checkBox = document.getElementById(id);
		if (checkBox.checked) {
			checkBox.value = 1;
		} else {
			checkBox.value = 0;
		}
	}

	/* Aktion wenn Speichern */
	function pushed_savebutton(id) {
		var allVals = [];
		var timerNr = (id - 17) / 20;
		allVals.push(timerNr);
		var start = id - 17 + 1;
		for(var i=start; i<id; i++) {
			allVals.push(document.getElementById(i).value);
		}
		FW_cmd(FW_root+ \'?XHR=1"'.$FW_CSRF.'"&cmd={FW_pushed_savebutton("'.$name.'","\'+allVals+\'","'.$FW_room_dupl.'")}\');
	}
	</script>';

	return $html;
}

### for function from pushed_savebutton ###
sub FW_pushed_savebutton {
	my $name = shift;
	my $hash = $defs{$name};
	my $selected_buttons = shift;														# neu,alle,alle,alle,alle,alle,00,Beispiel,on,0,0,0,0,0,0,0,0
	my @selected_buttons = split("," , $selected_buttons);
	my $timer = $selected_buttons[0];
	my $timers_count = 0;																		# Timer by counting
	my $timers_count2 = 0;																	# need to check 1 + 1
	my $timers_diff = 0;																		# need to check 1 + 1
	my $FW_room_dupl = shift;
	my $cnt_names = scalar(@selected_buttons);
	my $devicefound = 0;                                    # to check device exists

	my $timestamp = TimeNow();                              # Time now -> 2016-02-16 19:34:24
	my @timestamp_values = split(/-|\s|:/ , $timestamp);    # Time now splitted
	my ($sec, $min, $hour, $mday, $month, $year) = ($timestamp_values[5], $timestamp_values[4], $timestamp_values[3], $timestamp_values[2], $timestamp_values[1], $timestamp_values[0]);

	Log3 $name, 4, "$name: FW_pushed_savebutton is running";

	foreach my $d (sort keys %{$hash->{READINGS}}) {
		if ($d =~ /^Timer_(\d+)$/) {
			$timers_count++;
			$timers_count2 = $1 * 1;
			if ($timers_count != $timers_count2 && $timers_diff == 0) {  # only for diff
				$timer = $timers_count;
				$timers_diff = 1;
			}
		}
	}

	for(my $i = 0;$i < $cnt_names;$i++) {
		Log3 $name, 5, "$name: FW_pushed_savebutton | ".$names[$i]." -> ".$selected_buttons[$i];
		## to set time to check input ##
		if ($i >= 1 && $i <=6 && ( $selected_buttons[$i] ne "alle" && $selected_buttons[$i] ne "SA" && $selected_buttons[$i] ne "SU" )) {
			$sec = $selected_buttons[$i] if ($i == 6);
			$min = $selected_buttons[$i] if ($i == 5);
			$hour = $selected_buttons[$i] if ($i == 4);
			$mday = $selected_buttons[$i] if ($i == 3);
			$month = $selected_buttons[$i]-1 if ($i == 2);
			$year = $selected_buttons[$i]-1900 if ($i == 1);
		}

		if ($i == 7) {
			Log3 $name, 5, "$name: FW_pushed_savebutton | check: exists device or name -> ".$selected_buttons[$i];

			foreach my $d (sort keys %defs) {
				if (defined($defs{$d}{NAME}) && $defs{$d}{NAME} eq $selected_buttons[$i]) {
					$devicefound++;
					Log3 $name, 5, "$name: FW_pushed_savebutton | ".$selected_buttons[$i]." is checked and exists";
				}
			}
		}

		if ($i == 8) {
			Log3 $name, 5, "$name: FW_pushed_savebutton | ".$names[$i]." is NOT exists";
			return "ERROR: device not exists or no description! NO timer saved!" if ($devicefound == 0 && ($selected_buttons[$i] eq "on" || $selected_buttons[$i] eq "off"));
		}
	}

	return "ERROR: The time is in the past. Please set a time in the future!" if ((time() - fhemTimeLocal($sec, $min, $hour, $mday, $month, $year)) > 0);
	return "ERROR: The next switching point is too small!" if ((fhemTimeLocal($sec, $min, $hour, $mday, $month, $year) - time()) < 60);

	readingsDelete($hash,"Timer_".sprintf("%02s", $timer)."_set") if ($selected_buttons[8] ne "*" && ReadingsVal($name, "Timer_".sprintf("%02s", $timer)."_set", 0) ne "0");

	my $oldValue = ReadingsVal($name,"Timer_".sprintf("%02s", $selected_buttons[0]) ,0);
	my @Value_split = split(/,/ , $oldValue);
	$oldValue = $Value_split[7];
	my $newValue = substr($selected_buttons,(index($selected_buttons,",") + 1));
	@Value_split = split(/,/ , $newValue);
	$newValue = $Value_split[7];

	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, "Timer_".sprintf("%02s", $selected_buttons[0]) , substr($selected_buttons,(index($selected_buttons,",") + 1)));

	my $state = "Timer ".$selected_buttons[0]." saved";
	my $userattrName = "Timer_".sprintf("%02s", $selected_buttons[0])."_set:textField-long";
	my $reload = 0;

	if (($oldValue eq "on" || $oldValue eq "off") && $newValue eq "*") {
		$state = "Timer_".sprintf("%02s", $selected_buttons[0])." is save and added to userattr";
		addToDevAttrList($name,$userattrName);
		addStructChange("modify", $name, "attr $name userattr");                             # note with question mark
		$reload++;
	}

	if ($oldValue eq "*" && ($newValue eq "on" || $newValue eq "off")) {
		$state = "Timer_".sprintf("%02s", $selected_buttons[0])." is save and deleted from userattr";
		Timer_delFromUserattr($hash,$userattrName) if ($attr{$name}{userattr});
		addStructChange("modify", $name, "attr $name userattr");                             # note with question mark
		$reload++;
	}

	readingsBulkUpdate($hash, "state" , $state, 1);
	readingsEndUpdate($hash, 1);

	FW_directNotify("FILTER=room=$FW_room_dupl", "#FHEMWEB:WEB", "location.reload('true')", "") if ($FW_room_dupl);
	FW_directNotify("FILTER=$name", "#FHEMWEB:WEB", "location.reload('true')", "") if ($reload != 0);    # need to view question mark

	Timer_Check($hash) if ($selected_buttons[16] eq "1" && ReadingsVal($name, "internalTimer", "stop") eq "stop");

	return;
}

### for delete Timer value from userattr ###
sub Timer_delFromUserattr($$) {
	my $hash = shift;
	my $deleteTimer = shift;
	my $name = $hash->{NAME};

	if ($attr{$name}{userattr} =~ /$deleteTimer/) {
		delFromDevAttrList($name, $deleteTimer);
		Log3 $name, 3, "$name: delete $deleteTimer from userattr Attributes";
	}
}

### for Check ###
sub Timer_Check($) {
	my ($hash) = @_;
	my $name = $hash->{NAME};
	my @timestamp_values = split(/-|\s|:/ , TimeNow());		# Time now (2016-02-16 19:34:24) splitted in array
	my $dayOfWeek = strftime('%w', localtime);						# Wochentag
	$dayOfWeek = 7 if ($dayOfWeek eq "0");								# Sonntag nach hinten (Position 14 im Array)
	my $intervall = 60;                                   # Intervall to start new InternalTimer (standard)			
	my $cnt_activ = 0;                                    # counter for activ timers
	my $Simulation_only = AttrVal($name,"Simulation_only","off");
	my ($seconds, $microseconds) = gettimeofday();
	my @sunriseValues = split(":" , sunrise_abs("REAL"));	# Sonnenaufgang (06:34:24) splitted in array
	my @sunsetValues = split(":" , sunset_abs("REAL"));		# Sonnenuntergang (19:34:24) splitted in array

	Log3 $name, 4, "$name: Check is running, Sonnenaufgang $sunriseValues[0]:$sunriseValues[1]:$sunriseValues[2], Sonnenuntergang $sunsetValues[0]:$sunsetValues[1]:$sunsetValues[2]";
	Log3 $name, 4, "$name: Check is running, drift $microseconds microSeconds";

	foreach my $d (keys %{$hash->{READINGS}}) {
		if ($d =~ /^Timer_\d+$/) {
			my @values = split("," , $hash->{READINGS}->{$d}->{VAL});
			#Jahr  Monat Tag   Stunde Minute Sekunde Gerät              Aktion Mo Di Mi Do Fr Sa So aktiv
			#alle, alle, alle, alle,  alle,  00,     BlueRay_Player_LG, on,    0, 0, 0, 0, 0, 0, 0, 0
			#0     1     2     3      4      5       6                  7      8  9  10 11 12 13 14 15
			my $set = 1;
			if ($values[15] == 1) {                                 # Timer aktiv
				$cnt_activ++;
				$values[3] = $sunriseValues[0] if $values[3] eq "SA";	# Stunde Sonnenaufgang
				$values[4] = $sunriseValues[1] if $values[4] eq "SA";	# Minute Sonnenaufgang
				$values[3] = $sunsetValues[0] if $values[3] eq "SU";	# Stunde Sonnenuntergang
				$values[4] = $sunsetValues[1] if $values[4] eq "SU";	# Stunde Sonnenuntergang
				for (my $i = 0;$i < 5;$i++) {													# Jahr, Monat, Tag, Stunde, Minute
					$set = 0 if ($values[$i] ne "alle" && $values[$i] ne $timestamp_values[$i]);
				}
				$set = 0 if ($values[(($dayOfWeek*1) + 7)] eq "0");		# Wochentag
				$set = 0 if ($values[5] eq "00" && $timestamp_values[5] ne "00");				# Sekunde (Intervall 60)
				$set = 0 if ($values[5] ne "00" && $timestamp_values[5] ne $values[5]);	# Sekunde (Intervall 10)
				$intervall = 10 if ($values[5] ne "00");
				Log3 $name, 4, "$name: $d - set=$set intervall=$intervall dayOfWeek=$dayOfWeek column array=".(($dayOfWeek*1) + 7)." (".$values[($dayOfWeek*1) + 7].") $values[0]-$values[1]-$values[2] $values[3]:$values[4]:$values[5]";
				if ($set == 1) {
					Log3 $name, 4, "$name: $d - set $values[6] $values[7] ($dayOfWeek, $values[0]-$values[1]-$values[2] $values[3]:$values[4]:$values[5])";
					CommandSet($hash, $values[6]." ".$values[7]) if ($Simulation_only ne "on" && $values[7] ne "*");
					my $state = "$d set $values[6] $values[7] accomplished";
					if ($Simulation_only ne "on" && $values[7] eq "*") {
						if ($attr{$name}{$d."_set"}) {
							Log3 $name, 5, "$name: $d - exec at command: ".$attr{$name}{$d."_set"};
							my $ret = AnalyzeCommandChain(undef, SemicolonEscape($attr{$name}{$d."_set"}));     # { Log 1, "3333333: TEST" }
							Log3 $name, 3, "$name: $d\_set - ERROR: $ret" if($ret);
						} else {
							$state = "$d missing userattr to work!";
						}
					}
					readingsSingleUpdate($hash, "state" , "$state", 1);
					Log3 $name, 3, "$name: $d - set $values[6] $values[7]" if ($Simulation_only eq "on" && $values[5] eq $timestamp_values[5]);
				}
			}
		}
	}

	if ($intervall == 60) {
	 if ($timestamp_values[5] != 0 && $cnt_activ > 0) {
			$intervall = 60 - $timestamp_values[5];
			Log3 $name, 3, "$name: time difference too large! interval=$intervall, Sekunde=$timestamp_values[5]";
		}
	}
	## calculated from the starting point at 00 10 20 30 40 50 if Seconds interval active ##
	if ($intervall == 10) {
		if ($timestamp_values[5] % 10 != 0 && $cnt_activ > 0) {
			$intervall = $intervall - ($timestamp_values[5] % 10);
			Log3 $name, 3, "$name: time difference too large! interval=$intervall, Sekunde=$timestamp_values[5]";
		}
	}
	$intervall = ($intervall - $microseconds / 1000000); # Korrektur Zeit wegen Drift
	RemoveInternalTimer($hash);
	InternalTimer(gettimeofday()+$intervall, "Timer_Check", $hash, 0) if ($cnt_activ > 0);

	readingsBeginUpdate($hash);
	readingsBulkUpdate($hash, "state" , "no timer active") if ($cnt_activ == 0 && ReadingsVal($name, "internalTimer", "stop") ne "stop");
	readingsBulkUpdate($hash, "internalTimer" , "stop") if ($cnt_activ == 0 && ReadingsVal($name, "internalTimer", "stop") ne "stop");
	readingsBulkUpdate($hash, "internalTimer" , $intervall, 0) if($cnt_activ > 0);
	readingsEndUpdate($hash, 1);
}

# Eval-Rückgabewert für erfolgreiches
# Laden des Moduls
1;


# Beginn der Commandref

=pod
=item [helper|device|command]
=item summary Kurzbeschreibung in Englisch was MYMODULE steuert/unterstützt
=item summary_DE Kurzbeschreibung in Deutsch was MYMODULE steuert/unterstützt

=begin html

<a name="Timer"></a>
<h3>Timer Modul</h3>
<ul>
The timer module is a programmable timer.<br><br>
In Fonted you can define new times and actions. The smallest possible definition of an action is a 10 second interval.<br>
Use the drop-down menus to make the settings. Only after pressing the <code> Speichern </ code> button the setting is accepted.<br>
Defined options are displayed with a tick <b>&#10003;</b> and Deactivations are displayed with <b>&#10007;</b>.
<br><br><br>

<b>Define</b><br>
	<ul><code>define &lt;NAME&gt; Timer</code><br><br>
		<u>example:</u>
		<ul>
		define timer Timer
		</ul>
	</ul><br>

<b>Set</b><br>
	<ul>
		<a name="addTimer"></a>
		<li>addTimer: Adds a new timer</li><a name=""></a>
		<a name="deleteTimer"></a>
		<li>deleteTimer: Deletes the selected timer</li><a name=""></a>
		<a name="saveTimers"></a>
		<li>saveTimers: Saves the set timers in a file (<code>Timers.txt</code>)</li>
		<a name="sortTimer"></a>
		<li>sortTimer: Sorts the saved timers alphabetically.</li>
	</ul><br><br>

<b>Get</b><br>
	<ul>
		<a name="loadTimers"></a>
		<li>loadTimers: Loads a saved configuration</li><a name=""></a>
	</ul><br><br>

<b>Attribute</b><br>
	<ul><li><a href="#disable">disable</a></li></ul><br>
	<ul><li><a name="Border_Cell">Border_Cell</a><br>
	Shows the cell frame. (on | off = default)</li><a name=" "></a></ul><br>
	<ul><li><a name="Border_Table">Border_Table</a><br>
	Shows the table border. (on | off = default)</li><a name=" "></a></ul><br>
	<ul><li><a name="Timer_preselection">Timer_preselection</a><br>
	Sets the input values ​​for a new timer to the current time. (on | off = default)</li><a name=" "></a></ul><br>
	<ul><li><a name="Show_DeviceInfo">Show_DeviceInfo</a><br>
	Shows the additional information (alias | comment, standard off)</li><a name=" "></a></ul><br>
	<ul><li><a name="Simulation_only">Simulation_only</a><br>
	Turns off the action to be taken and writes a log output. (on | off = standard)</li><a name=" "></a></ul><br>

	<b><i>Generierte Readings</i></b><br>
	<li>Timer_xx<br>
	Memory values ​​of the individual timer</li><br>
	<li>internalTimer<br>
	State of the internal timer (stop or Interval until the next call)</li><br>

</ul>
=end html


=begin html_DE

<a name="Timer"></a>
<h3>Timer Modul</h3>
<ul>
Das Timer Modul ist eine programmierbare Schaltuhr.<br><br>
Im Fonted k&ouml;nnen Sie neue Zeitpunkte und Aktionen definieren. Die kleinstm&ouml;gliche Definition einer Aktion ist ein 10 Sekunden Intervall.<br>
Mittels der Dropdown Menüs k&ouml;nnen Sie die Einstellungen vornehmen. Erst nach dem dr&uuml;cken auf den <code>Speichern</code> Knopf wird die Einstellung &uuml;bernommen.<br>
Gesetzte Optionen werden mit einem Haken <b>&#10003;</b> dargestellt und Deaktivierungen werden mittels <b>&#10007;</b> dargestellt.
<br><br><br>

<b>Define</b><br>
	<ul><code>define &lt;NAME&gt; Timer</code><br><br>
		<u>Beispiel:</u>
		<ul>
		define Schaltuhr Timer
		</ul>
	</ul><br>

<b>Set</b><br>
	<ul>
		<a name="addTimer"></a>
		<li>addTimer: F&uuml;gt einen neuen Timer hinzu.</li><a name=""></a>
		<a name="deleteTimer"></a>
		<li>deleteTimer: L&ouml;scht den ausgew&auml;hlten Timer.</li><a name=""></a>
		<a name="saveTimers"></a>
		<li>saveTimers: Speichert die eingestellten Timer in einer Datei. (<code>Timers.txt</code>)</li>
		<a name="sortTimer"></a>
		<li>sortTimer: Sortiert die gespeicherten Timer alphabetisch.</li>
	</ul><br><br>

<b>Get</b><br>
	<ul>
		<a name="loadTimers"></a>
		<li>loadTimers: L&auml;d eine gespeicherte Konfiguration.</li><a name=""></a>
	</ul><br><br>

<b>Attribute</b><br>
	<ul><li><a href="#disable">disable</a></li></ul><br>
	<ul><li><a name="Border_Cell">Border_Cell</a><br>
	Blendet den Cellrahmen ein. (on | off = standard)</li><a name=" "></a></ul><br>
	<ul><li><a name="Border_Table">Border_Table</a><br>
	Blendet den Tabellenrahmen ein. (on | off = standard)</li><a name=" "></a></ul><br>
	<ul><li><a name="Timer_preselection">Timer_preselection</a><br>
	Setzt die Eingabewerte bei einem neuen Timer auf die aktuelle Zeit. (on | off = standard)</li><a name=" "></a></ul><br>
	<ul><li><a name="Show_DeviceInfo">Show_DeviceInfo</a><br>
	Blendet die Zusatzinformation ein. (alias | comment, standard off)</li><a name=" "></a></ul><br>
	<ul><li><a name="Simulation_only">Simulation_only</a><br>
	Schaltet die auszuführende Aktion aus und gibt nur eine Logausgabe wieder. (on | off = standard)</li><a name=" "></a></ul><br>

	<b><i>Generierte Readings</i></b><br>
	<li>Timer_xx<br>
	Speicherwerte des einzelnen Timers</li><br>
	<li>internalTimer<br>
	Zustand des internen Timers (stop oder oder Intervall bis zum n&auml;chsten Aufruf)</li><br>

</ul>
=end html_DE

# Ende der Commandref
=cut