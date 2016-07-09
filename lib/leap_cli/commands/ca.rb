module LeapCli; module Commands

  desc "Manage X.509 certificates"
  command :cert do |cert|

    cert.desc 'Creates two Certificate Authorities (one for validating servers and one for validating clients).'
    cert.long_desc 'See see what values are used in the generation of the certificates (like name and key size), run `leap inspect provider` and look for the "ca" property. To see the details of the created certs, run `leap inspect <file>`.'
    cert.command :ca do |ca|
      ca.action do |global_options,options,args|
        assert_config! 'provider.ca.name'
        generate_new_certificate_authority(:ca_key, :ca_cert, provider.ca.name)
        generate_new_certificate_authority(:client_ca_key, :client_ca_cert, provider.ca.name + ' (client certificates only!)')
      end
    end

    cert.desc 'Creates or renews a X.509 certificate/key pair for a single node or all nodes, but only if needed.'
    cert.long_desc 'This command will a generate new certificate for a node if some value in the node has changed ' +
                   'that is included in the certificate (like hostname or IP address), or if the old certificate will be expiring soon. ' +
                   'Sometimes, you might want to force the generation of a new certificate, ' +
                   'such as in the cases where you have changed a CA parameter for server certificates, like bit size or digest hash. ' +
                   'In this case, use --force. If <node-filter> is empty, this command will apply to all nodes.'
    cert.arg_name 'FILTER'
    cert.command :update do |update|
      update.switch 'force', :desc => 'Always generate new certificates', :negatable => false
      update.action do |global_options,options,args|
        update_certificates(manager.filter!(args), options)
      end
    end

    cert.desc 'Creates a Diffie-Hellman parameter file, needed for forward secret OpenVPN ciphers.' # (needed for server-side of some TLS connections)
    cert.command :dh do |dh|
      dh.action do |global_options,options,args|
        generate_dh
      end
    end

    cert.desc "Creates a CSR for use in buying a commercial X.509 certificate."
    cert.long_desc "Unless specified, the CSR is created for the provider's primary domain. "+
      "The properties used for this CSR come from `provider.ca.server_certificates`, "+
      "but may be overridden here."
    cert.command :csr do |csr|
      csr.flag 'domain', :arg_name => 'DOMAIN', :desc => 'Specify what domain to create the CSR for.'
      csr.flag ['organization', 'O'], :arg_name => 'ORGANIZATION', :desc => "Override default O in distinguished name."
      csr.flag ['unit', 'OU'], :arg_name => 'UNIT', :desc => "Set OU in distinguished name."
      csr.flag 'email', :arg_name => 'EMAIL', :desc => "Set emailAddress in distinguished name."
      csr.flag ['locality', 'L'], :arg_name => 'LOCALITY', :desc => "Set L in distinguished name."
      csr.flag ['state', 'ST'], :arg_name => 'STATE', :desc => "Set ST in distinguished name."
      csr.flag ['country', 'C'], :arg_name => 'COUNTRY', :desc => "Set C in distinguished name."
      csr.flag :bits, :arg_name => 'BITS', :desc => "Override default certificate bit length"
      csr.flag :digest, :arg_name => 'DIGEST', :desc => "Override default signature digest"
      csr.action do |global_options,options,args|
        generate_csr(global_options, options, args)
      end
    end
  end

  protected

  #
  # will generate new certificates for the specified nodes, if needed.
  #
  def update_certificates(nodes, options={})
    require 'leap_cli/x509'
    assert_files_exist! :ca_cert, :ca_key, :msg => 'Run `leap cert ca` to create them'
    assert_config! 'provider.ca.server_certificates.bit_size'
    assert_config! 'provider.ca.server_certificates.digest'
    assert_config! 'provider.ca.server_certificates.life_span'
    assert_config! 'common.x509.use'

    nodes.each_node do |node|
      node.warn_if_commercial_cert_will_soon_expire
      if !node.x509.use
        remove_file!([:node_x509_key, node.name])
        remove_file!([:node_x509_cert, node.name])
      elsif options[:force] || node.cert_needs_updating?
        node.generate_cert
      end
    end
  end

  #
  # yields client key and cert suitable for testing
  #
  def generate_test_client_cert(prefix=nil)
    require 'leap_cli/x509'
    cert = CertificateAuthority::Certificate.new
    cert.serial_number.number = cert_serial_number(provider.domain)
    cert.subject.common_name = [prefix, random_common_name(provider.domain)].join
    cert.not_before = X509.yesterday
    cert.not_after  = X509.yesterday.advance(:years => 1)
    cert.key_material.generate_key(1024) # just for testing, remember!
    cert.parent = client_ca_root
    cert.sign! client_test_signing_profile
    yield cert.key_material.private_key.to_pem, cert.to_pem
  end

  private

  def generate_new_certificate_authority(key_file, cert_file, common_name)
    require 'leap_cli/x509'
    assert_files_missing! key_file, cert_file
    assert_config! 'provider.ca.name'
    assert_config! 'provider.ca.bit_size'
    assert_config! 'provider.ca.life_span'

    root = X509.new_ca(provider.ca, common_name)

    write_file!(key_file, root.key_material.private_key.to_pem)
    write_file!(cert_file, root.to_pem)
  end

  def generate_dh
    require 'leap_cli/x509'
    long_running do
      if cmd_exists?('certtool')
        log 0, 'Generating DH parameters (takes a long time)...'
        output = assert_run!('certtool --generate-dh-params --sec-param high')
        output.sub!(/.*(-----BEGIN DH PARAMETERS-----.*-----END DH PARAMETERS-----).*/m, '\1')
        output << "\n"
        write_file!(:dh_params, output)
      else
        log 0, 'Generating DH parameters (takes a REALLY long time)...'
        output = OpenSSL::PKey::DH.generate(3248).to_pem
        write_file!(:dh_params, output)
      end
    end
  end

  #
  # hints:
  #
  # inspect CSR:
  #   openssl req -noout -text -in files/cert/x.csr
  #
  # generate CSR with openssl to see how it compares:
  #   openssl req -sha256 -nodes -newkey rsa:2048 -keyout example.key -out example.csr
  #
  # validate a CSR:
  #   http://certlogik.com/decoder/
  #
  # nice details about CSRs:
  #   http://www.redkestrel.co.uk/Articles/CSR.html
  #
  def generate_csr(global_options, options, args)
    require 'leap_cli/x509'
    assert_config! 'provider.domain'
    assert_config! 'provider.name'
    assert_config! 'provider.default_language'
    assert_config! 'provider.ca.server_certificates.bit_size'
    assert_config! 'provider.ca.server_certificates.digest'

    server_certificates      = provider.ca.server_certificates
    options[:domain]       ||= provider.domain
    options[:organization] ||= provider.name[provider.default_language]
    options[:country]      ||= server_certificates['country']
    options[:state]        ||= server_certificates['state']
    options[:locality]     ||= server_certificates['locality']
    options[:bits]         ||= server_certificates.bit_size
    options[:digest]       ||= server_certificates.digest

    unless global_options[:force]
      assert_files_missing! [:commercial_key, options[:domain]], [:commercial_csr, options[:domain]],
        :msg => 'If you really want to create a new key and CSR, remove these files first or run with --force.'
    end

    X509.create_csr_and_cert(options)
  end

end; end
