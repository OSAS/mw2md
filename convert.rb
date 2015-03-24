#!/bin/ruby

require 'fileutils'
require 'nokogiri'
require 'pandoc-ruby'
require 'wikicloth'
require 'kramdown'
require 'yaml'
require 'sanitize'
require 'csv'

def html_clean(html)
  html
    .gsub(/ target="_blank"/, '')
end

# Authors
wiki_author = {}

CSV.foreach('authors.csv') do |col|
  wiki_author[col[0].downcase] = { name: col[1], email: col[2] }
  wiki_author[col[0].downcase][:name] = col[0] if col[1].strip == ''
end

path = '/tmp/mw2md-output'
FileUtils.mkdir_p path
`cd #{path} && git init && cd -`

mw_xml = open 'dump.xml'
mw = Nokogiri::XML(mw_xml)

number_of_pages = mw.css('page').count
current_page = 0

mw.css('page').each do |page|
  current_page += 1

  title = page.css('title').text

  next if title.match(/^File:/)

  authors = page.css('username').map { |u| u.text.downcase }.sort.uniq

  page.css('revision').each do |rev|
    wikitext = rev.css('text').text

    id = rev.css('id').text
    timestamp = rev.css('timestamp').text
    username = rev.css('username').text
    comment = rev.css('comment').text.gsub(/\/\*|\*\//, '').strip
    category = wikitext.match(/\[\[Category\:([^\]]*)\]\]/i)
    category = category[1] if category
    category_dirs = category.downcase.strip.split(/[|\/]/).first if category
    dirs = title.downcase.split(/[:\/]/)
    filename = dirs.pop
    dirs = dirs.join('/').strip
    dirs = nil if dirs.empty?

    dir = category_dirs || dirs || 'uncategorized'

    output = true
    pandoc_conversion = true

    if output == true
      begin
        html = if pandoc_conversion
                 PandocRuby.convert(
                   wikitext, :s, {
                     from: :mediawiki,
                     to:   :markdown_github
                   },
                   'atx-headers',
                   'normalize'
                 )
               else
                 # wikitext
                 wiki_html = WikiCloth::Parser.new(data: wikitext).to_html

                 PandocRuby.convert(
                   wiki_html, :s, {
                     from: :html,
                     to: :markdown_github
                   },
                   'atx-headers'
                 )
               end
      rescue
        puts 'Error in conversion. Skipping to next page.'
        next
      end

      output = html
               .gsub(/\\([_#\$])/, '\\1')
               .gsub(/ "wikilink"\)/, ')')
               .gsub(/^- /, '* ')
               .gsub(/^`(.*)`$/, '      \\1')

      dir.gsub(/[_\s:]/, '-')

      begin
        FileUtils.mkdir_p "#{path}/#{dir}"
      rescue
        puts 'Error creating directory!'
      end

      frontmatter = {
        'title'         => title.split(/[:\/]/).pop,
        'category'      => category_dirs,
        'authors'       => authors.join(', '),
        'wiki_category' => category,
        'wiki_title'    => title,
        # "wiki_id"       => id
      }.select { |_, val| !val.nil? }.to_yaml

      complete = "#{frontmatter}---\n#{output}"

      ext = '.html.md'

      full_file = "#{dir.strip}/#{filename.strip}#{ext}"
                  .downcase
                  .squeeze(' ')
                  .gsub(/[_\s:]/, '-')
                  .gsub(/-+/, '-')
                  .gsub(/["']/, '')
                  .squeeze('-')

      percent = ((0.0 + current_page) / number_of_pages * 100).round(1)

      puts "Writing (#{current_page}/#{number_of_pages}) #{percent}% (MWID: #{id}) #{full_file}..."

      begin
        File.write "#{path}/#{full_file}", complete
      rescue
        puts 'Error writing file!'
      end

      begin
        `cd #{path} && git add * && git commit -a --author="#{username.downcase} <#{username.downcase}@wiki.ovirt.org>" --date="#{timestamp}" -m "#{comment.strip.empty? ? 'Updated' : comment.gsub(/"/, "'")}" && cd -`
      rescue
        puts 'Error committing!'
      end
    end
  end
end
