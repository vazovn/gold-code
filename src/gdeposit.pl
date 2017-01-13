#! /usr/bin/perl -wT
################################################################################
#
# Make a deposit
#
# File   :  gdeposit
#
################################################################################
#                                                                              #
#                        Copyright (c) 2003, 2004, 2005                        #
#                  Pacific Northwest National Laboratory,                      #
#                         Battelle Memorial Institute.                         #
#                             All rights reserved.                             #
#                                                                              #
################################################################################
#                                                                              #
#     Redistribution and use in source and binary forms, with or without       #
#     modification, are permitted provided that the following conditions       #
#     are met:                                                                 #
#                                                                              #
#     � Redistributions of source code must retain the above copyright         #
#     notice, this list of conditions and the following disclaimer.            #
#                                                                              #
#     � Redistributions in binary form must reproduce the above copyright      #
#     notice, this list of conditions and the following disclaimer in the      #
#     documentation and/or other materials provided with the distribution.     #
#                                                                              #
#     � Neither the name of Battelle nor the names of its contributors         #
#     may be used to endorse or promote products derived from this software    #
#     without specific prior written permission.                               #
#                                                                              #
#     THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS      #
#     "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT        #
#     LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS        #
#     FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE           #
#     COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,      #
#     INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,     #
#     BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;         #
#     LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER         #
#     CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT       #
#     LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN        #
#     ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE          #
#     POSSIBILITY OF SUCH DAMAGE.                                              #
#                                                                              #
################################################################################

use strict;
use vars qw($log $time_division $verbose @ARGV %supplement $quiet $VERSION);
use lib qw(/opt/gold/lib /opt/gold/lib/perl5);
use FindBin;
use Getopt::Long 2.24 qw(:config no_ignore_case);
use autouse 'Pod::Usage' => qw(pod2usage);
use Gold;
use Gold::Global;

Main:
{
    $log->debug("Command line arguments: @ARGV");

    # Parse Command Line Arguments
    my (
        $help,    $man,        $amount,  $account,   $description,
        $limit,   $allocation, $endTime, $startTime, $callType,
        $version, $hours,      $project, $machine,   $user
    );
    GetOptions(
        'z=s'       => \$amount,
        'a=i'       => \$account,
        'i=i'       => \$allocation,
        's=s'       => \$startTime,
        'e=s'       => \$endTime,
        'L=i'       => \$limit,
        'c=s'       => \$callType,
        'd=s'       => \$description,
        'p=s'       => \$project,
        'm=s'       => \$machine,
        'u=s'       => \$user,
        'hours|h'   => \$hours,
        'debug'     => \&Gold::Client::enableDebug,
        'help|?'    => \$help,
        'man'       => \$man,
        'quiet'     => \$quiet,
        'verbose|v' => \$verbose,
        'where'     => \&Gold::Client::parseSupplement,
        'option'    => \&Gold::Client::parseSupplement,
        'version|V' => \$version,
    ) or pod2usage(2);

    # Use sole remaining argument as amount if present
    if ($#ARGV == 0) { $amount = $ARGV[0]; }

    # Display usage if necessary
    pod2usage(2) if $help;
    if ($man)
    {
        if ($< == 0)    # Cannot invoke perldoc as root
        {
            my $id = eval { getpwnam("nobody") };
            $id = eval { getpwnam("nouser") } unless defined $id;
            $id = -2                          unless defined $id;
            $<  = $id;
        }
        $> = $<;                         # Disengage setuid
        $ENV{PATH} = "/bin:/usr/bin";    # Untaint PATH
        delete @ENV{'IFS', 'CDPATH', 'ENV', 'BASH_ENV'};
        if ($0 =~ /^([-\/\w\.]+)$/) { $0 = $1; }    # Untaint $0
        else { die "Illegal characters were found in \$0 ($0)\n"; }
        pod2usage(-exitstatus => 0, -verbose => 2);
    }

    # Display version if requested
    if ($version)
    {
        print "Gold version $VERSION\n";
        exit 0;
    }

    # Check for required arguments
    pod2usage(2)
      if ! defined $account
          && ! defined $project
          && ! defined $machine
          && ! defined $user;

    # Check for conflicting arguments
    pod2usage(2)
      if defined $account
          && (   defined $project
              || defined $machine
              || defined $user);

    # Convert hours to seconds if specified
    if ($hours)
    {
        $time_division = 3600;
    }
    if (defined $amount)
    {
        $amount = $amount * $time_division;
    }
    if (defined $limit)
    {
        $limit = $limit * $time_division;
    }

    # If project, user or machine is specified, determine account id if unique
    # otherwise display a list of accounts to choose from
    if (defined $project || defined $user || defined $machine)
    {
        # Query Accounts the project, user or machine can charge to
        my $request = new Gold::Request(object => "Account", action => "Query");
        $request->setSelection("Id", "Sort");
        $request->setSelection("Name");
        $request->setCondition("Id", $account) if defined $account;
        $request->setOption("Project", $project) if defined $project;
        $request->setOption("User",    $user)    if defined $user;
        $request->setOption("Machine", $machine) if defined $machine;
        $request->setOption("UseRules", "True");
        $log->info("Built request: ", $request->toString());

        # Obtain Response
        my $response = $request->getResponse();
        my $count    = $response->getCount();

        if (! defined $count || $count <= 0)
        {
            my $serverConfigFile = "${FindBin::Bin}/../etc/goldd.conf";
            open SERVERCONFIG, "$serverConfigFile"
              or die(
                "There are no accounts for the specified user/machine/project. Please respecify the deposit with a valid account id. Note -- the server config file ($serverConfigFile) could not be opened [$!] so it could not be determined whether account.autogen was set to automatically create the account for you.\n"
              );
            my $serverConfig = new Data::Properties();
            $serverConfig->load(\*SERVERCONFIG);
            close SERVERCONFIG;
            if (
                $serverConfig->get_property(
                    "account.autogen", $ACCOUNT_AUTOGEN
                ) =~ /true/i
              )
            {
                my $request =
                  new Gold::Request(object => "Account", action => "Create");
                my @names = ();
                # Add project member
                if (defined $project)
                {
                    $request->setOption("Project", $project);
                    push @names, "$project" if $project !~ /ANY|NONE/;
                }
                else
                {
                    $request->setOption("Project", "ANY");
                }

                # Add machine member
                if (defined $machine)
                {
                    $request->setOption("Machine", $machine);
                    push @names, "on $machine"
                      if $machine !~ /ANY|MEMBERS|NONE/;
                }
                else
                {
                    $request->setOption("Machine", "ANY");
                }

                # Add user member
                if (defined $user)
                {
                    $request->setOption("User", $user);
                    push @names, "for $user" if $user !~ /ANY|MEMBERS|NONE/;
                }
                else
                {
                    $request->setOption("User", "ANY");
                }

                # Set account name and description
                $request->setAssignment("Name", join ' ', @names) if @names;
                $request->setAssignment("Description", "Auto-Generated");

                my $response = $request->getResponse();
                if ($response->getStatus() eq "Success")
                {
                    $account = $response->getDatumValue("Id");
                    $response->setMessage(
                        "Successfully created Account $account");
                    &Gold::Client::displayResponse($response);
                }

                else
                {
                    my $responseMessage = $response->getMessage();
                    $response = new Gold::Response()
                      ->failure("Unable to create account: $responseMessage");
                    &Gold::Client::displayResponse($response);
                    exit 74;
                }
            }

            else
            {
                # Display an error message and exit
                $response =
                  new Gold::Response()
                  ->failure(
                    "There are no accounts for the specified user/machine/project. Please respecify the deposit with a valid account id."
                  );
                &Gold::Client::displayResponse($response);
                exit 74;
            }
        }
        elsif ($count == 1)
        {
            # Deposit into the unique account
            $account = $response->getDatumValue("Id");
        }
        else
        {
            # Display a list of account names and break
            print
              "The specified user/machine/project has multiple accounts. Please respecify the deposit with the appropriate account id.\n";
            $verbose = 1;
            &Gold::Client::displayResponse($response);
            exit 74;
        }
    }

    # Issue the deposit

    # Build request
    my $request = new Gold::Request(object => "Account", action => "Deposit");
    $request->setOption("Id",          $account);
    $request->setOption("Amount",      $amount) if defined $amount;
    $request->setOption("Allocation",  $allocation) if defined $allocation;
    $request->setOption("StartTime",   $startTime) if defined $startTime;
    $request->setOption("EndTime",     $endTime) if defined $endTime;
    $request->setOption("CreditLimit", $limit) if defined $limit;
    $request->setOption("CallType",    $callType) if defined $callType;
    $request->setOption("Description", $description) if defined $description;
    $request->setOption("ShowHours",   "True") if defined $hours;
    Gold::Client::buildSupplements($request);
    $log->info("Built request: ", $request->toString());

    # Obtain Response
    my $response = $request->getResponse();
#if (defined($project) && $response->getStatus() eq "Success")
#{
#  my $count = $response->getCount();
#  $response = new Gold::Response()->success($count, "Successfully deposited $count credits into project $project");
#}

    # Print out the response
    &Gold::Client::displayResponse($response);

    # Exit with status code
    my $code = $response->getCode();
    $log->info("$0 (PID $$) Exiting with status code ($code)");
    exit $code / 10;
}

##############################################################################

__END__

=head1 NAME

gdeposit - issue a deposit

=head1 SYNOPSIS

B<gdeposit> {B<-a> I<account_id> | { B<-p> I<project_name> &| B<-u> I<user_name> &| B<-m> I<machine_name>}} [B<-i> I<allocation_id>] [B<-s> I<start_time>] [B<-e> I<end_time>] [B<-L> I<credit_limit>] [B<-d> I<description>] [B<-h>, B<--hours>] [B<--debug>] [B<-?>, B<--help>] [B<--man>] [B<--quiet>] [B<-v>, B<--verbose>] [B<-V>, B<--version>] [[B<-z>] I<amount>]

=head1 DESCRIPTION


B<gdeposit> is used to make time-bounded deposits into accounts. if there is exactly one debitable account for the specified criteria, a deposit will be made into that account. If multiple accounts match the specified criteria, a list of matching accounts will be displayed and you will be prompted to respecify the deposit against one of the enumerated accounts. If no accounts match your criteria, if the account.autogen configuration parameter is true, an account will be created and a deposit made into it, otherwise the deposit will fail (the account will need to be created with B<gmkaccount>).

=head1 OPTIONS

=over 4

=item B<-a> I<account_id>

the account into which the deposit will be made

=item B<-m> I<machine_name>

If a single account matches the specified machine along with the other criteria, a deposit will be made into that account. If account.autogen is set to true and no account matches the specifications, an account will be created for the specified machine along with the other specified criteria and a deposit will be made into that account.

=item B<-p> I<project_name>

If a single account matches the specified project along with the other criteria, a deposit will be made into that account. If account.autogen is set to true and no account matches the specifications, an account will be created for the specified project along with the other specified criteria and a deposit will be made into that account.

=item B<-u> I<user_name>

If a single account matches the specified user along with the other criteria, a deposit will be made into that account. If account.autogen is set to true and no account matches the specifications, an account will be created for the specified user along with the other specified criteria and a deposit will be made into that account.

=item [B<-z>] I<amount>

amount to deposit

=item B<-i> I<allocation_id>

specifies that the deposit should go into the specified allocation. This option is incompatible with the B<-L> option.

=item B<-s> I<start_time>

start time for the allocation to be credited in the format [YYYY-MM-DD[ hh:mm:ss]|-infinity|infinity|now]. The start time will default to -infinity.

=item B<-e> I<end_time>

end time for the allocation to be credited in the format [YYYY-MM-DD[ hh:mm:ss]|-infinity|infinity|now]. The end time will default to infinity.

=item B<-L> I<credit_limit>

if a credit limit is specified, a new allocation will be created with the specified credit limit. This option is incompatible with the B<-i> option.

=item B<-c> I<call_type>

Call types are used in support of distributed accounting for when multiple organizations are involved. This may be one of Normal, Back or Forward, with Normal being the default.

=item B<-d> I<description>

reason for the deposit

=item B<-h | --hours>

treat currency as specified in hours. In systems where the currency is measured in resource-seconds (like processor-seconds), this option allows the amount and credit limit to be specified in resource-hours.

=item B<--debug>

log debug info to screen

=item B<-? | --help>

brief help message

=item B<--man>

full documentation

=item B<--quiet>

suppress headers and success messages

=item B<-v | --verbose>

display modified objects

=item B<-V | --version>

display Gold package version

=back

=head1 AUTHOR

Scott Jackson, Scott.Jackson@pnl.gov

=cut

