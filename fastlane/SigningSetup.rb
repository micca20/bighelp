require "base64"
require "fileutils"
require "openssl"
require "securerandom"

# Called only by the optional ci_prepare_signing lane, never by a release lane.
def prepare_ci_signing
  require_release_settings!
  required = %w[RUNNER_TEMP ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY IOS_DISTRIBUTION_P12_PASSWORD]
  missing = required.select { |name| ENV[name].to_s.empty? }
  UI.user_error!("Missing signing setup inputs: #{missing.join(', ')}") unless missing.empty?
  unless ENV["GITHUB_ACTIONS"] == "true" && ENV["SIGNING_SETUP_CONFIRMATION"] == "CREATE NEW DISTRIBUTION CERTIFICATE"
    UI.user_error!("Use the manually confirmed Prepare signing identity workflow")
  end
  password = ENV.fetch("IOS_DISTRIBUTION_P12_PASSWORD")
  UI.user_error!("Use a password-manager-generated P12 password of at least 16 characters") if password.length < 16 || password.match?(/[\r\n\0]/)

  root = File.join(ENV.fetch("RUNNER_TEMP"), "loopdy-signing-setup")
  raw = File.join(root, "private")
  exported = File.join(root, "export")
  keychain = File.join(root, "setup.keychain-db")
  old_umask = File.umask(0o077)
  begin
    # The workflow creates root privately before redirecting diagnostic output there.
    FileUtils.mkdir_p(raw, mode: 0o700)
    FileUtils.mkdir_p(exported, mode: 0o700)
    keychain_password = SecureRandom.hex(32)
    create_keychain(path: keychain, password: keychain_password, default_keychain: false,
      unlock: true, timeout: 0, lock_when_sleeps: false)
    api_key = app_store_connect_api_key(key_id: ENV.fetch("ASC_KEY_ID"),
      issuer_id: ENV.fetch("ASC_ISSUER_ID"), key_content: ENV.fetch("ASC_PRIVATE_KEY"),
      duration: 1_200, in_house: false)
    app = Spaceship::ConnectAPI::App.find(APP_IDENTIFIER)
    UI.user_error!("The API key cannot access the expected Loopdy app") unless app && app.id == APP_STORE_APP_ID
    ENV["CER_KEYCHAIN_PATH"] = keychain
    get_certificates(api_key: api_key, development: false, generate_apple_certs: true,
      force: true, output_path: raw, keychain_path: keychain,
      keychain_password: keychain_password, skip_set_partition_list: true)

    certificate_id = ENV.fetch("CER_CERTIFICATE_ID")
    UI.user_error!("Unexpected certificate identifier") unless certificate_id.match?(/\A[A-Za-z0-9]+\z/)
    certificate = OpenSSL::X509::Certificate.new(File.binread(File.join(raw, "#{certificate_id}.cer")))
    # fastlane cert writes PEM private-key data with a .p12 suffix; it is NOT an encrypted P12.
    private_key = OpenSSL::PKey.read(File.binread(File.join(raw, "#{certificate_id}.p12")))
    subject = certificate.subject.to_a.to_h { |name, value, _type| [name, value] }
    unless certificate.check_private_key(private_key) && subject["OU"] == DEVELOPMENT_TEAM && subject["CN"].to_s.start_with?("Apple Distribution:")
      UI.user_error!("The generated identity does not match the expected Apple distribution team")
    end
    # OpenSSL's explicit legacy PBE interoperates with macOS security import.
    # High iteration counts and the separately stored strong password protect the exported key.
    package = OpenSSL::PKCS12.create(password, "Loopdy CI Apple Distribution", private_key, certificate,
      [], "PBE-SHA1-3DES", "PBE-SHA1-3DES", 100_000, 100_000).to_der
    roundtrip = OpenSSL::PKCS12.new(package, password)
    UI.user_error!("Encrypted identity verification failed") unless roundtrip.certificate.check_private_key(roundtrip.key)
    File.binwrite(File.join(exported, "distribution.p12"), package)
    File.write(File.join(exported, "distribution.p12.base64.txt"), Base64.strict_encode64(package))
  ensure
    # cert can create the remote certificate before a local import fails: preserve its ID for recovery.
    begin
      ids = Dir.glob(File.join(raw, "*.cer")).map { |path| File.basename(path, ".cer") }
        .select { |id| id.match?(/\A[A-Za-z0-9]+\z/) }
      if ENV["GITHUB_STEP_SUMMARY"] && !ids.empty?
        File.open(ENV.fetch("GITHUB_STEP_SUMMARY"), "a") do |summary|
          summary.puts("Apple certificate ID: #{ids.join(', ')}. Save this ID before retrying a failed setup.")
        end
      end
    ensure
      begin
        delete_keychain(keychain_path: keychain) if File.exist?(keychain)
      ensure
        FileUtils.rm_rf(raw)
        ENV.delete("CER_KEYCHAIN_PATH")
        File.umask(old_umask)
      end
    end
  end
end
