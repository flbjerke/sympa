# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4
# $Id$

# Sympa - SYsteme de Multi-Postage Automatique
#
# Copyright (c) 1997, 1998, 1999 Institut Pasteur & Christophe Wolfhugel
# Copyright (c) 1997, 1998, 1999, 2000, 2001, 2002, 2003, 2004, 2005,
# 2006, 2007, 2008, 2009, 2010, 2011 Comite Reseau des Universites
# Copyright (c) 2011, 2012, 2013, 2014, 2015, 2016, 2017 GIP RENATER
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

package Sympa::Spindle::TransformIncoming;

use strict;
use warnings;
use Encode qw();
use English;    # FIXME: drop $POSTMATCH usage
use MIME::EncWords;

use Conf;
use Sympa::Language;
use Sympa::Log;
use Sympa::Message::Plugin;
use Sympa::Regexps;
use Sympa::Template;
use Sympa::Tools::Data;
use Sympa::Topic;

use base qw(Sympa::Spindle);

my $language = Sympa::Language->instance;
my $log      = Sympa::Log->instance;

# Old name: (part of) Sympa::List::distribute_msg().
sub _twist {
    my $self    = shift;
    my $message = shift;

    Sympa::Message::Plugin::execute('pre_distribute', $message);

    my $list = $message->{context};

    my $robot = $list->{'domain'};

    # Update msg_count, and returns the new X-Sequence, if any.
    $message->{xsequence} = $list->get_next_sequence;

    ## Loading info msg_topic file if exists, add X-Sympa-Topic
    my $topic;
    if ($list->is_there_msg_topic) {
        $topic = Sympa::Topic->load($message);
    }
    if ($topic) {
        # Add X-Sympa-Topic: header.
        $message->add_header('X-Sympa-Topic', $topic->{topic});
    }

    # Hide the sender if the list is anonymized
    if ($list->{'admin'}{'anonymous_sender'}) {
        foreach my $field (@{$Conf::Conf{'anonymous_header_fields'}}) {
            $message->delete_header($field);
        }

        # override From: and Message-ID: fields.
        # Note that corresponding Resent-*: fields will be removed.
        $message->replace_header('From',
            $list->{'admin'}{'anonymous_sender'});
        $message->delete_header('Resent-From');
        my $new_id =
            $list->{'name'} . '.' . $message->{xsequence} . '@anonymous';
        $message->replace_header('Message-Id', "<$new_id>");
        $message->delete_header('Resent-Message-Id');

        # Duplicate topic file by new message ID.
        if ($topic) {
            $topic->store({context => $list, message_id => $new_id});
        }

        ## Virer eventuelle signature S/MIME
    }

    # Add Custom Subject

    my $parsed_tag;
    if ($list->{'admin'}{'custom_subject'}) {
        my $custom_subject = $list->{'admin'}{'custom_subject'};

        # Check if custom_subject parameter is parsable.
        my $data = {
            list => {
                name     => $list->{'name'},
                sequence => $message->{xsequence},
            },
        };
        my $template = Sympa::Template->new(undef);
        unless ($template->parse($data, [$custom_subject], \$parsed_tag)) {
            $log->syslog('err', 'Can\'t parse custom_subject of list %s: %s',
                $list, $template->{last_error});

            undef $parsed_tag;
        }
    }
    if ($list->{'admin'}{'custom_subject'} and defined $parsed_tag) {
        my $subject_field = $message->{'decoded_subject'};
        $subject_field = '' unless defined $subject_field;
        ## Remove leading and trailing blanks
        $subject_field =~ s/^\s*(.*)\s*$/$1/;

        ## Search previous subject tagging in Subject
        my $custom_subject = $list->{'admin'}{'custom_subject'};

        ## tag_regexp will be used to remove the custom subject if it is
        ## already present in the message subject.
        ## Remember that the value of custom_subject can be
        ## "dude number [%list.sequence"%]" whereas the actual subject will
        ## contain "dude number 42".
        my $list_name_escaped = $list->{'name'};
        $list_name_escaped =~ s/(\W)/\\$1/g;
        my $tag_regexp = $custom_subject;
        ## cleanup, just in case dangerous chars were left
        $tag_regexp =~ s/([^\w\s\x80-\xFF])/\\$1/g;
        ## Replaces "[%list.sequence%]" by "\d+"
        $tag_regexp =~ s/\\\[\\\%\s*list\\\.sequence\s*\\\%\\\]/\\d+/g;
        ## Replace "[%list.name%]" by escaped list name
        $tag_regexp =~
            s/\\\[\\\%\s*list\\\.name\s*\\\%\\\]/$list_name_escaped/g;
        ## Replaces variables declarations by "[^\]]+"
        $tag_regexp =~ s/\\\[\\\%\s*[^]]+\s*\\\%\\\]/[^]]+/g;
        ## Takes spaces into account
        $tag_regexp =~ s/\s+/\\s+/g;

        # Add subject tag

        ## If subject is tagged, replace it with new tag
        ## Splitting the subject in two parts :
        ##   - what will be before the custom subject (probably some "Re:")
        ##   - what will be after it : the original subject sent to the list.
        ## The custom subject is not kept.
        my $before_tag;
        my $after_tag;
        if ($custom_subject =~ /\S/) {
            $subject_field =~ s/\s*\[$tag_regexp\]\s*/ /;
        }
        $subject_field =~ s/\s+$//;

        # truncate multiple "Re:" and equivalents.
        my $re_regexp = Sympa::Regexps::re();
        if ($subject_field =~ /^\s*($re_regexp\s*)($re_regexp\s*)*/) {
            ($before_tag, $after_tag) = ($1, $POSTMATCH);
        } else {
            ($before_tag, $after_tag) = ('', $subject_field);
        }

        ## Encode subject using initial charset

        ## Don't try to encode the subject if it was not originally encoded.
        if ($message->{'subject_charset'}) {
            $subject_field = MIME::EncWords::encode_mimewords(
                Encode::decode_utf8(
                    $before_tag . '[' . $parsed_tag . '] ' . $after_tag
                ),
                Charset     => $message->{'subject_charset'},
                Encoding    => 'A',
                Field       => 'Subject',
                Replacement => 'FALLBACK'
            );
        } else {
            $subject_field =
                $before_tag . ' '
                . MIME::EncWords::encode_mimewords(
                Encode::decode_utf8('[' . $parsed_tag . ']'),
                Charset  => Conf::lang2charset($language->get_lang),
                Encoding => 'A',
                Field    => 'Subject'
                )
                . ' '
                . $after_tag;
        }

        $message->delete_header('Subject');
        $message->add_header('Subject', $subject_field);
    }

    ## Prepare tracking if list config allow it
    my @apply_tracking = ();

    push @apply_tracking,
        'dsn'
        if Sympa::Tools::Data::smart_eq(
        $list->{'admin'}{'tracking'}->{'delivery_status_notification'}, 'on');
    push @apply_tracking,
        'mdn'
        if Sympa::Tools::Data::smart_eq(
        $list->{'admin'}{'tracking'}->{'message_disposition_notification'},
        'on')
        or (
        Sympa::Tools::Data::smart_eq(
            $list->{'admin'}{'tracking'}
                ->{'message_disposition_notification'}, 'on_demand'
        )
        and $message->get_header('Disposition-Notification-To')
        );

    if (@apply_tracking) {
        $message->{shelved}{tracking} = join '+', @apply_tracking;

        # remove notification request becuse a new one will be inserted if
        # needed
        $message->delete_header('Disposition-Notification-To');
    }

    ## Remove unwanted headers if present.
    if ($list->{'admin'}{'remove_headers'}) {
        foreach my $field (@{$list->{'admin'}{'remove_headers'}}) {
            $message->delete_header($field);
        }
    }

    1;
}

1;
__END__

=encoding utf-8

=head1 NAME

Sympa::Spindle::TransformIncoming -
Process to transform messages - first stage

=head1 DESCRIPTION

TBD.

=head1 SEE ALSO

L<Sympa::Message>,
L<Sympa::Message::Plugin>,
L<Sympa::Spindle>,
L<Sympa::Spindle::DistributeMessage>,
L<Sympa::Topic>.

=head1 HISTORY

L<Sympa::Spindle::TransformIncoming> appeared on Sympa 6.2.13.

=cut
