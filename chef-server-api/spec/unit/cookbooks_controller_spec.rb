#
# Author:: Daniel DeLeo (<dan@opscode.com>)
# Copyright:: Copyright (c) 2011 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require File.expand_path(File.dirname(__FILE__) + '/../spec_helper')
require File.expand_path(File.dirname(__FILE__) + '/../spec_model_helper')
require 'chef/node'
require 'pp'

describe "Cookbooks Controller" do
  before do
    Merb.logger.set_log(StringIO.new)
  end

  MAXMAJOR=25
  describe "when several versions of multiple cookbooks exist" do
    before do
      @cookbook_a_versions = (0...7).map { |i| "1.0.#{i}"}
      @cookbook_b_versions = (0...3).map { |i| "#{MAXMAJOR}.0.#{i}" }
      Chef::CookbookVersion.stub!(:cdb_list).and_return("cookbook-a" => @cookbook_a_versions, "cookbook-b" => @cookbook_b_versions)
      Chef::CookbookVersion.stub!(:cdb_list_latest).and_return('cookbook-a' => '1.0.6', 'cookbook-b' => '#{MAXMAJOR}.0.2')
      Chef::CookbookVersion.stub!(:cdb_by_name).with('cookbook-a').and_return("cookbook-a" => @cookbook_a_versions)
    end

    describe "when handling requests from 0.10 and newer clients" do
      it "lists the latest version of all cookbooks" do
        expected = {}
        expected_cookbook_a_data = [ @cookbook_a_versions.map {|v| {"url" => "#{root_url}/cookbooks/cookbook-a/#{v}", "version" => v}}.last ]
        expected['cookbook-a'] = {"url" => "#{root_url}/cookbooks/cookbook-a", "versions" =>  expected_cookbook_a_data}
        expected_cookbook_b_data = [ @cookbook_b_versions.map {|v| {"url" => "#{root_url}/cookbooks/cookbook-b/#{v}", "version" => v}}.last ]
        expected['cookbook-b'] = {"url" => "#{root_url}/cookbooks/cookbook-b", "versions" => expected_cookbook_b_data}
        get_json('/cookbooks').should == expected
      end

      it "shows the versions of a cookbook" do
        expected = {}
        expected_cookbook_a_data = @cookbook_a_versions.map {|v| {"url" => "#{root_url}/cookbooks/cookbook-a/#{v}", "version" => v}}.reverse
        expected['cookbook-a'] = {"url" => "#{root_url}/cookbooks/cookbook-a", "versions" => expected_cookbook_a_data}
        get_json('/cookbooks/cookbook-a').should == expected
      end

      cookbook_version = "#{MAXMAJOR}.0.3"
      it "downloads a file from a cookbook" do
        cookbook = make_cookbook("cookbook-a", "#{cookbook_version}")
        cookbook.checksums["1234"] = nil
        stub_checksum("1234")
        Chef::CookbookVersion.should_receive(:cdb_load).with("cookbook-a", "#{cookbook_version}").and_return(cookbook)
        expected = {}
        expected_cookbook_a_data = @cookbook_a_versions.map {|v| {"url" => "#{root_url}/cookbooks/cookbook-a/#{v}", "version" => v}}.reverse
        expected['cookbook-a'] = {"url" => "#{root_url}/cookbooks/cookbook-a", "versions" => expected_cookbook_a_data}
        response = get("/cookbooks/cookbook-a/#{cookbook_version}/files/1234") do |controller|
          stub_authentication(controller)
          controller.should_receive(:send_file).with("/var/chef/checksums/12/1234").and_return("file-content")
        end
        response.status.should == 200
        response.body.should == "file-content"
      end

      it "gets an error in case of missing file on download" do
        cookbook = make_cookbook("cookbook-a", "#{cookbook_version}")
        cookbook.checksums["1234"] = nil
        stub_checksum("1234", false)
        Chef::CookbookVersion.should_receive(:cdb_load).with("cookbook-a", "#{cookbook_version}").and_return(cookbook)
        expected = {}
        expected_cookbook_a_data = @cookbook_a_versions.map {|v| {"url" => "#{root_url}/cookbooks/cookbook-a/#{v}", "version" => v}}.reverse
        expected['cookbook-a'] = {"url" => "#{root_url}/cookbooks/cookbook-a", "versions" => expected_cookbook_a_data}
        lambda do
          response = get("/cookbooks/cookbook-a/#{cookbook_version}/files/1234") do |controller|
            stub_authentication(controller)
          end
        end.should raise_error(Merb::ControllerExceptions::InternalServerError, /File with checksum 1234 not found in the repository/)
      end
    end

    describe "when handling requests from 0.9 clients" do
      it "lists the latest versions of cookbooks by URL" do
        expected = {}
        expected['cookbook-a'] = "#{root_url}/cookbooks/cookbook-a"
        expected['cookbook-b'] = "#{root_url}/cookbooks/cookbook-b"
        get_json('/cookbooks', {}, {'HTTP_X_CHEF_VERSION' => '0.9.14'} ).should == expected
      end

      it "shows the versions of a cookbook by URL" do
        expected = {'cookbook-a' => @cookbook_a_versions}
        get_json('/cookbooks/cookbook-a', {}, {'HTTP_X_CHEF_VERSION' => '0.9.14'}).should == expected
      end
    end
  end

  describe "when uploading a cookbook" do
    before do
      @cookbook = make_cookbook("cookbook1", "1.0.0")
    end

    describe "and the cookbook is new" do
      it "should upload a standard cookbook" do
        Chef::CookbookVersion.stub!(:cdb_load).and_raise(Chef::Exceptions::CouchDBNotFound)
        @cookbook.should_receive(:cdb_save).and_return(true)
        response = put_json("/cookbooks/#{@cookbook.name}/#{@cookbook.version}", @cookbook)
      end

      it "should upload a frozen cookbook" do
        @cookbook.freeze_version
        Chef::CookbookVersion.stub!(:cdb_load).and_raise(Chef::Exceptions::CouchDBNotFound)
        @cookbook.should_receive(:cdb_save).and_return(true)
        response = put_json("/#{@cookbook.save_url}", @cookbook)
      end
    end

    describe "and the cookbook already exists" do
      it "should overwrite the existing version" do
        Chef::CookbookVersion.stub!(:cdb_load).and_return(@cookbook)
        @cookbook.should_receive(:cdb_save).and_return(true)
        response = put_json("/#{@cookbook.save_url}", @cookbook)
      end

      it "should not overwrite a frozen version" do
        @cookbook.freeze_version
        Chef::CookbookVersion.stub!(:cdb_load).and_return(@cookbook)
        lambda do
          put_json("/#{@cookbook.save_url}", @cookbook)
        end.should raise_error(Merb::ControllerExceptions::Conflict, /The cookbook (\S+) at version (\S+) is frozen/)
      end

      it "should overwrite a frozen version if forced" do
        @cookbook.freeze_version
        Chef::CookbookVersion.stub!(:cdb_load).and_return(@cookbook)
        @cookbook.should_receive(:cdb_save).and_return(true)
        response = put_json("/#{@cookbook.force_save_url}", @cookbook)
      end
    end
  end
end
