use strict;
use warnings;
use TAP::Harness;

# runtests() reports failures but does not exit with them, so CI would pass a
# failing suite without this.
my $aggregator = TAP::Harness->new({ verbosity => 1, color => 1 })->runtests('version.t', 'pool.t');
exit($aggregator->all_passed ? 0 : 1);
