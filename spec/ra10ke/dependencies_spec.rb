# frozen_string_literal: true

require 'r10k/puppetfile'
require 'spec_helper'
require 'ra10ke/dependencies'
require 'ra10ke'

RSpec::Mocks.configuration.allow_message_expectations_on_nil = true

RSpec.describe 'Ra10ke::Dependencies::Verification' do
  let(:instance) do
    pfile = R10K::Puppetfile.new(File.basename(puppetfile), nil, puppetfile, nil, false)
    Ra10ke::Dependencies::Verification.new(pfile)
  end

  let(:puppetfile) do
    File.join(fixtures_dir, 'Puppetfile')
  end

  context 'register_version_format' do
    it 'default contains semver' do
      expect(Ra10ke::Dependencies::Verification.version_formats).to have_key(:semver)
    end

    it 'add new version format' do
      Ra10ke::Dependencies::Verification.register_version_format(:test) do |_tags|
        nil
      end
      expect(Ra10ke::Dependencies::Verification.version_formats).to have_key(:test)
    end
  end

  context 'show output in table format' do
    let(:instance) do
      pfile = R10K::Puppetfile.new(File.basename(puppetfile), nil, puppetfile, nil, false)
      Ra10ke::Dependencies::Verification.new(pfile)
    end

    let(:puppetfile) do
      File.join(fixtures_dir, 'Puppetfile')
    end

    let(:processed_modules) do
      instance.outdated
    end

    it 'have dependencies array' do
      expect(processed_modules).to be_a Array
    end

    it 'show dependencies as table' do
      instance.print_table(processed_modules)
    end
  end

  context 'get_latest_ref' do
    context 'find latest semver tag' do
      let(:latest_tag) do
        'v1.1.0'
      end
      let(:test_tags) do
        {
          'v1.0.0' => nil,
          latest_tag => nil,
        }
      end

      it do
        expect(instance.get_latest_ref({
                                         'tags' => test_tags,
                                       })).to eq(latest_tag)
      end
    end

    context 'find latest tag with custom version format' do
      let(:latest_tag) do
        'latest'
      end
      let(:test_tags) do
        {
          'dev' => nil,
          latest_tag => nil,
        }
      end

      it do
        Ra10ke::Dependencies::Verification.register_version_format(:number) do |tags|
          tags.detect { |tag| tag == latest_tag }
        end
        expect(instance.get_latest_ref({
                                         'tags' => test_tags,
                                       })).to eq(latest_tag)
      end
    end

    context 'ignore peeled annotated tags' do
      it do
        expect(instance.get_latest_ref({
                                         'tags' => { 'v1.0.0' => nil, 'v1.0.0^{}' => nil },
                                       })).to eq('v1.0.0')
      end
    end

    context 'convert to ref' do
      it 'run rake task' do
        output_conversion = File.read(File.join(fixtures_dir, 'Puppetfile_git_conversion'))
        require 'ra10ke'
        Ra10ke::RakeTask.new do |t|
          t.basedir = fixtures_dir
        end
        expect { Rake::Task['r10k:print_git_conversion'].invoke }.to output(output_conversion).to_stdout
      end
    end
  end

  context 'commit sha refs' do
    let(:remote_refs) do
      {
        'branches' => { 'main' => { ref: 'refs/heads/main', sha: '4' * 40 } },
        'tags' => {
          # lightweight tag
          'v1.0.0' => { ref: 'refs/tags/v1.0.0', sha: '1' * 40 },
          # non-semver tag on the same commit as v2.0.0
          'stable' => { ref: 'refs/tags/stable', sha: '3' * 40 },
          # annotated tag
          'v2.0.0' => { ref: 'refs/tags/v2.0.0', sha: 'a' * 40 },
          'v2.0.0^{}' => { ref: 'refs/tags/v2.0.0^{}', sha: '3' * 40 },
        },
        'head' => { ref: 'HEAD', sha: '4' * 40 },
      }
    end

    context 'tag_commits' do
      it 'uses the peeled commit of annotated tags' do
        expect(instance.tag_commits(remote_refs)).to eq(
          'v1.0.0' => '1' * 40, 'stable' => '3' * 40, 'v2.0.0' => '3' * 40,
        )
      end
    end

    context 'get_latest_commit' do
      it 'compares a tagged sha to the latest tag' do
        expect(instance.get_latest_commit('1' * 40, remote_refs)).to eq(
          installed: '11111111 (v1.0.0)', latest: '33333333 (v2.0.0)', current: false,
        )
      end

      it 'prefers the latest tag when a commit has several tags' do
        expect(instance.get_latest_commit('3' * 40, remote_refs)).to eq(
          installed: '33333333 (v2.0.0)', latest: '33333333 (v2.0.0)', current: true,
        )
      end

      it 'compares an untagged sha to head' do
        expect(instance.get_latest_commit('2' * 40, remote_refs)).to eq(
          installed: '22222222', latest: '44444444', current: false,
        )
      end

      it 'compares head to head' do
        expect(instance.get_latest_commit('4' * 40, remote_refs)).to eq(
          installed: '44444444', latest: '44444444', current: true,
        )
      end

      it 'compares a tagged sha to head when no tag follows a known pattern' do
        refs = remote_refs.merge('tags' => { 'stable' => { ref: 'refs/tags/stable', sha: '1' * 40 } })
        expect(instance.get_latest_commit('1' * 40, refs)).to eq(
          installed: '11111111', latest: '44444444', current: false,
        )
      end
    end

    context 'processed_modules' do
      let(:puppetfile) do
        File.join(fixtures_dir, 'Puppetfile_with_sha')
      end

      before do
        allow(Git).to receive(:ls_remote).and_return(remote_refs)
        # skip resolving refs by cloning
        instance.puppetfile.modules.each { |mod| allow(mod).to receive(:version).and_return(mod.desired_ref) }
      end

      it 'compares shas to the latest tag or head' do
        expect(instance.processed_modules).to contain_exactly(
          { name: 'old_tag', installed: '11111111 (v1.0.0)', latest: '33333333 (v2.0.0)', type: 'git', message: :outdated },
          { name: 'latest_tag', installed: '33333333 (v2.0.0)', latest: '33333333 (v2.0.0)', type: 'git', message: :current },
          { name: 'untagged', installed: '22222222', latest: '44444444', type: 'git', message: :outdated },
          { name: 'tag', installed: 'v1.0.0', latest: 'v2.0.0', type: 'git', message: :outdated },
        )
      end
    end
  end
end
