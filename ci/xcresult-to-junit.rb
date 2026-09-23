#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "rexml/document"

input, output = ARGV
abort "usage: #{File.basename($PROGRAM_NAME)} RESULT.xcresult REPORT.xml" unless input && output

json, error, status = Open3.capture3(
  "xcrun", "xcresulttool", "get", "test-results", "tests", "--path", input, "--compact"
)
abort error unless status.success?

report = JSON.parse(json)
test_cases = []

walk = lambda do |node, ancestors|
  if node["nodeType"] == "Test Case"
    test_cases << [node, ancestors]
  else
    (node["children"] || []).each { |child| walk.call(child, ancestors + [node] ) }
  end
end
(report["testNodes"] || []).each { |node| walk.call(node, []) }
failure_message = lambda do |node|
  messages = []
  visit = lambda do |child|
    messages << (child["details"] || child["name"]) if child["nodeType"] == "Failure Message"
    (child["children"] || []).each { |descendant| visit.call(descendant) }
  end
  visit.call(node)
  messages.empty? ? (node["details"] || "Test failed") : messages.join("\n")
end


document = REXML::Document.new
document << REXML::XMLDecl.new("1.0", "UTF-8")
suite = document.add_element("testsuite", {
  "name" => File.basename(input, ".xcresult"),
  "tests" => test_cases.length.to_s,
  "failures" => test_cases.count { |node, _| node["result"] == "Failed" }.to_s,
  "errors" => test_cases.count { |node, _| node["result"] == "unknown" }.to_s,
  "skipped" => test_cases.count { |node, _| ["Skipped", "Expected Failure"].include?(node["result"]) }.to_s,
  "time" => test_cases.sum { |node, _| node.fetch("durationInSeconds", 0) }.to_s,
})

test_cases.each do |node, ancestors|
  class_name = ancestors.filter_map do |ancestor|
    ancestor["name"] if ["Unit test bundle", "UI test bundle", "Test Suite"].include?(ancestor["nodeType"])
  end.join(".")
  test_case = suite.add_element("testcase", {
    "name" => node.fetch("name"),
    "classname" => class_name,
    "time" => node.fetch("durationInSeconds", 0).to_s,
  })

  case node["result"]
  when "Failed"
    message = failure_message.call(node)
    test_case.add_element("failure", { "message" => message }).text = message
  when "unknown"
    message = node["details"] || "Test result is unknown"
    test_case.add_element("error", { "message" => message }).text = message
  when "Skipped", "Expected Failure"
    test_case.add_element("skipped")
  end
end

File.open(output, "w") { |file| document.write(file, 2) }
