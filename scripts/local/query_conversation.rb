#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "../../lib/conversation_service"

options = {
  question: ENV["CONVERSATION_QUESTION"],
  user_id: ENV["CONVERSATION_USER_ID"],
  subject_key: ENV["PERSONAL_SUBJECT_KEY"],
  limit: Integer(ENV.fetch("CONVERSATION_LIMIT", "20"))
}
begin
OptionParser.new do |parser|
  parser.on("--question TEXT") { |value| options[:question] = value }
  parser.on("--user-id ID") { |value| options[:user_id] = value }
  parser.on("--subject-key KEY") { |value| options[:subject_key] = value }
  parser.on("--limit N", Integer) { |value| options[:limit] = value }
end.parse!(ARGV)

raise ArgumentError, "--question is required" if options[:question].to_s.strip.empty?
service = ConversationService.new
puts JSON.generate(service.answer(question: options.fetch(:question), user_id: options[:user_id],
                                   subject_key: options[:subject_key], limit: options.fetch(:limit)))
rescue ConversationService::Error, ConversationProvider::Error, ConversationRetriever::Error,
       PersonalMemoryStore::Error, ArgumentError, OptionParser::ParseError => error
  warn error.message
  puts JSON.generate({ "answer_status" => "failed", "error" => error.message,
                       "global_evidence" => [], "personal_memory" => [] })
  exit 1
end
