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

  context 'tag_for_sha' do
    let(:remote_refs) do
      {
        'tags' => {
          'v1.0.0' => { sha: 'aaaa000000000000000000000000000000000000' },
          # annotated tag: the peeled "^{}" ref points at the commit
          'v1.1.0' => { sha: 'bbbb000000000000000000000000000000000000' },
          'v1.1.0^{}' => { sha: 'cccc000000000000000000000000000000000000' },
        },
      }
    end

    it 'finds a lightweight tag by its commit sha' do
      expect(instance.tag_for_sha(remote_refs, 'aaaa000000000000000000000000000000000000')).to eq('v1.0.0')
    end

    it 'finds an annotated tag by its peeled commit sha' do
      expect(instance.tag_for_sha(remote_refs, 'cccc000000000000000000000000000000000000')).to eq('v1.1.0')
    end

    it 'prefers the newest tag when a commit carries several' do
      remote_refs['tags']['v1.0.1^{}'] = { sha: 'cccc000000000000000000000000000000000000' }
      expect(instance.tag_for_sha(remote_refs, 'cccc000000000000000000000000000000000000')).to eq('v1.1.0')
    end

    it 'returns nil for a sha that is not a tag' do
      expect(instance.tag_for_sha(remote_refs, 'dddd000000000000000000000000000000000000')).to be_nil
    end
  end

  context 'sha pinned modules' do
    let(:puppetfile) do
      File.join(fixtures_dir, 'Puppetfile_with_commit_sha')
    end

    let(:released_refs) do
      {
        'head' => { sha: 'ffff000000000000000000000000000000000000' },
        'branches' => {},
        'tags' => {
          'v9.2.0' => { sha: 'eeee000000000000000000000000000000000000' },
          'v9.2.0^{}' => { sha: '999b265735d047ea691819533d64026f20cda31d' },
          'v10.0.0' => { sha: 'ffff000000000000000000000000000000000000' },
        },
      }
    end

    let(:unreleased_refs) do
      {
        'head' => { sha: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' },
        'branches' => {},
        'tags' => {},
      }
    end

    let(:pinned_shas) do
      {
        'released' => '999b265735d047ea691819533d64026f20cda31d',
        'unreleased' => 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      }
    end

    before do
      allow(Git).to receive(:ls_remote).with('https://github.com/example/released').and_return(released_refs)
      allow(Git).to receive(:ls_remote).with('https://github.com/example/unreleased').and_return(unreleased_refs)
      # r10k resolves refs by cloning, so stub the pin to stay offline
      instance.puppetfile.modules.each do |mod|
        allow(mod).to receive(:version).and_return(pinned_shas.fetch(mod.name))
      end
    end

    it 'compares a sha pinned release against the latest release' do
      mod = instance.processed_modules.find { |m| m[:name] == 'released' }
      expect(mod).to include(installed: 'v9.2.0', latest: 'v10.0.0', message: :outdated)
    end

    it 'reports a sha pinned to the latest release as current' do
      # repin to v10.0.0
      released_refs['tags']['v9.2.0^{}'] = { sha: 'dddd000000000000000000000000000000000000' }
      released_refs['tags']['v10.0.0^{}'] = { sha: '999b265735d047ea691819533d64026f20cda31d' }
      mod = instance.processed_modules.find { |m| m[:name] == 'released' }
      expect(mod).to include(installed: 'v10.0.0', latest: 'v10.0.0', message: :current)
    end

    it 'reports current when the pinned commit also carries the latest tag' do
      released_refs['tags']['v10.0.0^{}'] = { sha: '999b265735d047ea691819533d64026f20cda31d' }
      mod = instance.processed_modules.find { |m| m[:name] == 'released' }
      expect(mod).to include(installed: 'v10.0.0', latest: 'v10.0.0', message: :current)
    end

    it 'still tracks head when the tags follow no known version format' do
      released_refs['tags'] = {
        '2024-01-15' => { sha: '999b265735d047ea691819533d64026f20cda31d' },
        '2024-06-01' => { sha: 'dddd000000000000000000000000000000000000' },
      }
      mod = instance.processed_modules.find { |m| m[:name] == 'released' }
      expect(mod).to include(installed: '999b2657', latest: 'ffff0000', message: :outdated)
    end

    it 'still tracks head for a sha with no release attached' do
      mod = instance.processed_modules.find { |m| m[:name] == 'unreleased' }
      expect(mod).to include(installed: 'aaaaaaaa', latest: 'bbbbbbbb', message: :outdated)
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
end
