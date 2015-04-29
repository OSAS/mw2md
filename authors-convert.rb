#!/usr/bin/ruby

require 'csv'
require 'yaml'

config = YAML.load_file('config.yml')

csv_file = config['authors_csv'] || 'authors.csv'
yaml_file = config['authors_yaml'] || 'wiki_authors.yaml'

authors = {}

CSV.open(csv_file).each do |nick, name, email|
  nick.strip!
  name.strip!
  email.strip!

  if name == '' && email == ''
    authors[nick] = nil
  else
    authors[nick] ||= {}

    authors[nick]['name'] = name unless name == ''
    authors[nick]['email'] = email unless email == ''
  end
end

puts "Read from '#{csv_file}' and wrote to '#{yaml_file}'"
File.write yaml_file, authors.to_yaml.gsub(/^---\n/m, '')
