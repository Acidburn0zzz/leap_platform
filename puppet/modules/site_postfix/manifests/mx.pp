#
# configure mx node
#
class site_postfix::mx {

  $domain_hash         = hiera('domain')
  $domain              = $domain_hash['full_suffix']
  $host_domain         = $domain_hash['full']
  $cert_name           = hiera('name')
  $mynetworks          = join(hiera('mynetworks', ''), ' ')
  $rbls                = suffix(prefix(hiera('rbls', []), 'reject_rbl_client '), ',')

  $root_mail_recipient = hiera('contacts')
  $postfix_smtp_listen = 'all'

  include site_config::x509::cert
  include site_config::x509::key
  include site_config::x509::client_ca::ca
  include site_config::x509::client_ca::key

  postfix::config {
    'mynetworks':
      value => "127.0.0.0/8 [::1]/128 [fe80::]/64 ${mynetworks}";
    # Note: mydestination should not include @domain, because this is
    # used in virtual alias maps.
    'mydestination':
      value => "\$myorigin, localhost, localhost.\$mydomain";
    'myhostname':
      value => $host_domain;
    'mailbox_size_limit':
      value => '0';
    'home_mailbox':
      value => '';
    'virtual_mailbox_domains':
      value => 'deliver.local';
    'virtual_mailbox_base':
      value => '/var/mail/vmail';
    'virtual_mailbox_maps':
      value => 'static:Maildir/';
    # Note: virtual-aliases map will take precedence over leap_mx
    # lookup (tcp:localhost)
    'virtual_alias_maps':
      value => 'hash:/etc/postfix/virtual-aliases tcp:localhost:4242';
    'luser_relay':
      value => '';
    # uid and gid are set to an arbitrary hard-coded value here, this
    # must match the 'vmail' user block below
    'virtual_uid_maps':
      value => 'static:42424';
    'virtual_gid_maps':
      value => 'static:42424';
    'smtpd_tls_received_header':
      value => 'yes';
    # Note: we are setting this here, instead of in site_postfix::mx::smtp_tls
    # because the satellites need to have a different value
    'smtp_tls_security_level':
      value => 'may';
    # reject inbound mail to system users
    # see https://leap.se/code/issues/6829
    # this blocks *only* mails to system users, that don't appear in the
    # alias map
    'local_recipient_maps':
      value => '$alias_maps';
    'smtpd_milters':
      value => 'unix:/run/clamav/milter.ctl,unix:/var/run/opendkim/opendkim.sock';
    'milter_default_action':
      value => 'accept';
  }

  include site_postfix::mx::smtpd_checks
  include site_postfix::mx::checks
  include site_postfix::mx::smtp_tls
  include site_postfix::mx::smtpd_tls
  include site_postfix::mx::static_aliases
  include site_postfix::mx::rewrite_openpgp_header
  include clamav
  include postfwd

  # greater verbosity for debugging, take out for production
  #include site_postfix::debug

  # Make the 'vmail' user for leap-mx. This user is where all legitimate,
  # non-system mail is delivered so leap-mx can process it. Previously, we let
  # the system pick a uid/gid, but we need to know what they are set to in order
  # to set the virtual_uid_maps and virtual_gid_maps. Its a bit overkill write a
  # fact just for this, so instead we pick arbitrary numbers that seem unlikely
  # to be used and then use them in the postfix configuration
  user { 'vmail':
    ensure     => present,
    comment    => 'Leap Mailspool',
    home       => '/var/mail/vmail',
    shell      => '/bin/false',
    uid        => '42424',
    gid        => '42424',
    managehome => true,
  }

  class { 'postfix':
    preseed             => true,
    root_mail_recipient => $root_mail_recipient,
    smtp_listen         => 'all',
    mastercf_tail       =>
    "smtps     inet  n       -       -       -       -       smtpd
  -o smtpd_tls_wrappermode=yes
  -o smtpd_tls_security_level=encrypt
  -o smtpd_recipient_restrictions=\$smtps_recipient_restrictions
  -o smtpd_helo_restrictions=\$smtps_helo_restrictions
  -o smtpd_client_restrictions=
  -o cleanup_service_name=clean_smtps
clean_smtps	  unix	n	-	n	-	0	cleanup
  -o header_checks=pcre:/etc/postfix/checks/rewrite_openpgp_headers",
    require             => [
      Class['Site_config::X509::Key'],
      Class['Site_config::X509::Cert'],
      Class['Site_config::X509::Client_ca::Key'],
      Class['Site_config::X509::Client_ca::Ca'],
      User['vmail'] ]
  }
}
