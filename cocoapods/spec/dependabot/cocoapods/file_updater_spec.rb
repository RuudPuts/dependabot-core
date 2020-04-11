# frozen_string_literal: true

require "spec_helper"
require "dependabot/dependency"
require "dependabot/dependency_file"
require "dependabot/cocoapods/file_updater"
require_common_spec "file_updaters/shared_examples_for_file_updaters"

RSpec.describe Dependabot::CocoaPods::FileUpdater do
  it_behaves_like "a dependency file updater"

  let(:cocoapods_all_pods) do
    fixture("cocoapods", "all_pods", "all_pods.txt")
  end

  let(:cocoapods_deprecated_specs) do
    fixture("cocoapods", "podspecs", "deprecated_podspecs.txt")
  end

  let(:cocoapods_version_yaml) do
    fixture("cocoapods", "CocoaPods-Version.yml")
  end

  def stub_all_pods_versions_requests
    all_versions_files = File.join("spec", "fixtures", "cocoapods", "all_pods", "all_pods_versions_*.txt")
    Dir[all_versions_files].each do |file|
      versions_url = "#{COCOAPODS_CDN_HOST}/#{File.basename(file)}"
      stub_request(:get, versions_url).
          to_return(status: 200, body: File.read(file))
    end
  end

  def stub_all_spec_requests
    spec_paths = {
        "Nimble-0.0.1": "Specs/d/c/d/Nimble/0.0.1/Nimble.podspec.json",
        "Alamofire-3.0.1": "Specs/d/a/2/Alamofire/3.0.1/Alamofire.podspec.json",
        "Alamofire-3.5.1": "Specs/d/a/2/Alamofire/3.5.1/Alamofire.podspec.json",
        "Alamofire-4.5.0": "Specs/d/a/2/Alamofire/4.5.0/Alamofire.podspec.json",
        "Alamofire-4.5.1": "Specs/d/a/2/Alamofire/4.5.1/Alamofire.podspec.json",
        "Alamofire-4.6.0": "Specs/d/a/2/Alamofire/4.6.0/Alamofire.podspec.json",
        "AlamofireImage-4.1.0": "Specs/8/0/a/AlamofireImage/4.1.0/AlamofireImage.podspec.json"
    }

    Dir[File.join("spec", "fixtures", "cocoapods", "podspecs", "*.podspec.json")].each do |file|
      spec = File.basename(file, ".podspec.json")
      spec_path = spec_paths[spec.to_sym]
      versions_url = "#{COCOAPODS_CDN_HOST}/#{spec_path}"

      stub_request(:get, versions_url).
          to_return(status: 200, body: File.read(file))
    end
  end

  before do
    all_pods_url = "#{COCOAPODS_CDN_HOST}/all_pods.txt"
    stub_request(:get, all_pods_url).
        to_return(status: 200, body: cocoapods_all_pods)

    deprecated_specs_url = "#{COCOAPODS_CDN_HOST}/deprecated_podspecs.txt"
    stub_request(:get, deprecated_specs_url).
        to_return(status: 200, body: cocoapods_deprecated_specs)

    cocoapods_version_url = "#{COCOAPODS_CDN_HOST}/CocoaPods-version.yml"
    stub_request(:get, cocoapods_version_url).
        to_return(status: 200, body: cocoapods_version_yaml)

    github_version_url = "https://github.com/dependabot/Specs.git/CocoaPods-version.yml"
    stub_request(:get, github_version_url).
        to_return(status: 200, body: cocoapods_version_yaml)

    stub_all_pods_versions_requests
    stub_all_spec_requests
  end

  before do
    master_url = "https://api.github.com/repos/CocoaPods/Specs/commits/master"
    stub_request(:get, master_url).to_return(status: 304)
  end

  let(:updater) do
    described_class.new(
      dependency_files: [podfile, lockfile],
      dependencies: [dependency],
      credentials: [{
        "type" => "git_source",
        "host" => "github.com",
        "username" => "x-access-token",
        "password" => "token"
      }]
    )
  end

  let(:podfile) do
    Dependabot::DependencyFile.new(content: podfile_body, name: "Podfile")
  end

  let(:podfile_body) { fixture("cocoapods", "podfiles", "version_specified") }

  let(:lockfile) do
    Dependabot::DependencyFile.new(content: lockfile_body, name: "Podfile.lock")
  end

  let(:lockfile_body) { fixture("cocoapods", "lockfiles", "version_specified") }

  let(:dependency) do
    Dependabot::Dependency.new(
      name: "Alamofire",
      version: "4.0.0",
      previous_version: "3.0.0",
      requirements: [{
        requirement: "~> 4.0.0",
        file: "Podfile",
        source: nil,
        groups: []
      }],
      previous_requirements: [{
        requirement: "~> 3.0.0",
        file: "Podfile",
        source: nil,
        groups: []
      }],
      package_manager: "cocoapods"
    )
  end

  describe "#updated_dependency_files" do
    subject(:updated_files) { updater.updated_dependency_files }

    it "returns DependencyFile objects" do
      updated_files.each { |f| expect(f).to be_a(Dependabot::DependencyFile) }
    end

    its(:length) { is_expected.to eq(2) }

    describe "the updated podfile" do
      subject(:updated_podfile) do
        updated_files.find { |f| f.name == "Podfile" }
      end

      context "when the full version is specified" do
        let(:podfile_body) do
          fixture("cocoapods", "podfiles", "version_specified")
        end
        its(:content) { is_expected.to include "'Alamofire', '~> 4.0.0'" }
        its(:content) { is_expected.to include "'Nimble', '~> 2.0.0'" }
      end

      context "when the version is not specified" do
        let(:podfile_body) do
          fixture("cocoapods", "podfiles", "version_not_specified")
        end
        its(:content) { is_expected.to include "'Alamofire'\n" }
        its(:content) { is_expected.to include "'Nimble'\n" }
      end
    end

    describe "the updated lockfile" do
      subject(:file) { updated_files.find { |f| f.name == "Podfile.lock" } }

      context "when the old Podfile specified the version" do
        let(:podfile_body) do
          fixture("cocoapods", "podfiles", "version_specified")
        end

        it "locks the updated pod to the latest version" do
          expect(file.content).to include "Alamofire (4.0.1)"
        end

        it "doesn't change the version of the other (also outdated) pod" do
          expect(file.content).to include "Nimble (2.0.0)"
        end
      end

      context "with a private source" do
        before do
          specs_url =
            "https://api.github.com/repos/dependabot/Specs/commits/master"
          stub_request(:get, specs_url).to_return(status: 304)
        end

        let(:podfile_body) do
          fixture("cocoapods", "podfiles", "private_source")
        end

        it "locks the updated pod to the latest version" do
          expect(file.content).to include "Alamofire (4.3.0)"
        end
      end

      context "with a git source for one of the other dependencies" do
        let(:podfile_body) { fixture("cocoapods", "podfiles", "git_source") }

        let(:dependency) do
          Dependabot::Dependency.new(
            name: "Nimble",
            version: "6.0.0",
            previous_version: "3.0.0",
            requirements: [{
              requirement: "~> 6.0.0",
              file: "Podfile",
              source: nil,
              groups: []
            }],
            previous_requirements: [{
              requirement: "~> 3.0.0",
              file: "Podfile",
              source: nil,
              groups: []
            }],
            package_manager: "cocoapods"
          )
        end

        it "locks the updated pod to the latest version" do
          expect(file.content).to include "Nimble (6.0.1)"
        end

        it "leaves the other (git referencing) pod alone" do
          expect(file.content).
            to include "Alamofire: 1f72088aff8f6b40828dadd61be2e9a31beca01e"
        end

        it "generates the correct podfile checksum" do
          expect(file.content).
            to include "CHECKSUM: 2db781eacbb9b29370b899ba5cd95a2347a63bd4"
        end

        it "doesn't leave details of the access token in the lockfile" do
          expect(file.content).to_not include "x-oauth-basic"
        end
      end
    end
  end
end
