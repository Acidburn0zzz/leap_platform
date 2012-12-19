class site_apt {

  include ::apt
  include site_apt::dist_upgrade

  apt::apt_conf { '90disable-pdiffs':
    content => 'Acquire::PDiffs "false";';
  }

  include ::apt::unattended_upgrades
}
