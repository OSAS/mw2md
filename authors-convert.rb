#!/usr/bin/ruby

require 'csv'
require 'yaml'
require 'digest/md5'

def gravatize(email)
  Digest::MD5.hexdigest email.downcase.strip
end

config = YAML.load_file('config.yml')

csv_file = config['authors_csv'] || 'authors.csv'
yaml_file = config['authors_yaml'] || 'wiki_authors.yaml'

authors = {}

CSV.open(csv_file).each do |nick, name, email|
  nick.strip! if nick
  name.strip! if name
  email.strip! if email

  if (name == '' || name.nil?) && (email == '' || email.nil?)
    authors[nick] = nil
  else
    authors[nick] ||= {}

    authors[nick]['name'] = name unless name == '' || name.nil?
    authors[nick]['email'] = email unless email == '' || email.nil?
    authors[nick]['gravatar'] = gravatize email unless email == '' || email.nil?
  end
end

yaml_output = authors.to_yaml
              .gsub(/^---\n/m, '')
              .gsub(/^\w/, "\n\\0")
              .strip

File.write yaml_file, yaml_output

puts "Read from '#{csv_file}' and wrote to '#{yaml_file}'"
