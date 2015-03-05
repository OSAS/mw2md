#!/bin/ruby

require 'fileutils'
require 'nokogiri'
require 'pandoc-ruby'
require 'kramdown'

path = "output"
FileUtils.mkdir_p path

mw_xml = open "dump.xml"
mw = Nokogiri::XML(mw_xml)

#puts mw.css('title')

mw.css('page').each do |page|
  title = page.css('title').text

  page.css('revision').each do |rev|
    wikitext = rev.css('text').text

    id = rev.css('id').text
    timestamp = rev.css('timestamp').text
    username = rev.css('username').text
    comment = rev.css('comment').text
    category = wikitext.match(/\[\[Category\:(.*)\]\]/i)
    category = category[1] if category
    category_dir = category.downcase.strip.gsub(/\|/, '/') if category
    dirs = title.downcase.split(/[:\/]/)
    dirs.pop
    dirs = dirs.join('/')

    puts "#{dirs}\t#{category_dir}\t#{('same' if dirs == category_dir) || ('similar' if dirs && category_dir && !dirs.to_s.strip.empty? && !category_dir.to_s.strip.empty? && category_dir.to_s.match(Regexp.escape(dirs.to_s)) || dirs.to_s.match(Regexp.escape(category_dir.to_s)))}"

    #puts "| #{title} | #{username} | #{timestamp} | #{comment} |"
    #puts "#{title}‽#{username}‽#{timestamp}‽#{category}‽#{comment}"
    #puts category
    #puts username

    #puts wikitext.split(/\n/).last
    #puts wikitext[/[[Category:(.*)]]/i]

    output = false

    if output == true
      html = PandocRuby.convert(
        wikitext, :s, {
          from: :mediawiki,
          #to:   :html
          to:   :markdown_github
        },
        'atx-headers',
        'normalize',
        ''
        #'pipe_tables',
        #'escaped_line_breaks',
        #'blank_before_header',
        #'header_attributes',
        #'block_quotations',
        #'blank_before_blockquote',
        #'fenced_code_block',
        #'definition_lists',
        #'yaml_metadata-block',
        #'inline_code_attributes',
        #'raw_html',
        #'markdown_in_html_blocks',
        #'native_divs',
        #'native_spans',
        #'abbreviations',
        #'autolink_bare_uris',
        #'link_attributes',
      )

      output = html
            .gsub(/\\([_#\$])/, '\\1')
            .gsub(/ "wikilink"\)/, ')')
            .gsub(/^- /, '* ')
            .gsub(/^`(.*)`$/, '      \\1')
      #body = Nokogiri::HTML(html).css('body').to_s

      #puts Kramdown::Document.new(body, input: "html").to_kramdown

      puts output
    end
  end
end
