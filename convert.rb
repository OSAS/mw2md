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
  html.gsub(/ target="_blank"/, '')
end

def fix_links(md)
  matches = /^\[(\n+)\]: (.*)$/.match(md)
  # puts "MATCHES: #{matches.inspect}" if matches
  md
end

# Authors
wiki_author = {}

CSV.foreach('authors.csv') do |col|
  wiki_author[col[0].downcase] = { name: col[1], email: col[2] }
  wiki_author[col[0].downcase][:name] = col[0] if col[1].strip == ''
end

sanitize_config = Sanitize::Config
                  .merge(Sanitize::Config::RELAXED,
                         elements: Sanitize::Config::RELAXED[:elements] - ['span'],
                         attributes: {
                           'a' => %w(href title),
                           'table' => %w(class id)
                         })

PandocRuby.allow_file_paths = true

config = YAML.load_file('config.yml')

path = '/tmp/mw2md-output'
FileUtils.mkdir_p path

`git init #{path}`

mw_xml = open 'dump.xml'
mw = Nokogiri::XML(mw_xml)

number_of_pages = mw.css('page').count
current_page = 0

redirect = {}

mw.css('page').select { |page| page.css('redirect') }.each do |page|
  title = page.css('title').text
  redir = page.css('redirect').attr('title').text rescue ''

  next if title.match(/^File:/)

  unless redir.strip == ''
    # puts "Redirect! #{title} => #{redir}"
    redirect[title] = redir
  end
end

revision = []

mw.css('page').sort_by { |page| page.css('timestamp').text }.each do |page|
  title = page.css('title').text

  next if title.match(/^File:/)

  authors = page.css('username').map { |u| u.text.downcase }.sort.uniq

  page.css('revision').each do |rev|
    revision.push page: page,
                  revision: rev,
                  title: title,
                  authors: authors,
                  timestamp: rev.css('timestamp').text
  end
end

number_of_pages = revision.count

revision.sort_by { |r| r[:timestamp] }.each do |rev_info|
  current_page += 1

  rev = rev_info[:revision]
  title = rev_info[:title]
  authors = rev_info[:authors]

  # page.css('revision').each do |rev|
  wikitext = rev.css('text').text

  id = rev.css('id').text
  timestamp = rev.css('timestamp').text
  username = rev.css('username').text
  comment = rev.css('comment').text.gsub(/\/\*|\*\//, '').strip
  dirs = title.gsub(/&action=.*/, '').downcase.split(/[:\/]/)
  filename = dirs.pop.gsub(/&/, ' and ')
  dirs = dirs.join('/').strip
  dirs = nil if dirs.empty?

  category = wikitext.match(/\[\[Category\:([^\]]*)\]\]/i)
  category = category[1] if category.class == MatchData
  category_dirs = category.downcase.strip.split(/[|\/]/).first if category

  category_match = nil

  config['catmatch'].each do |k, v|
    category_match = v if filename.match(Regexp.new k)
  end

  config['rewrite'].each do |k, v|
    filename.gsub!(Regexp.new(k), v)
  end

  dir = category_match || category_dirs || dirs || 'uncategorized'

  config['rewrite_dirs'].each do |k, v|
    dir.gsub!(Regexp.new(k), v)
  end

  if title.match(/^(home|main page)$/i)
    dir = ''
    filename = 'index'
  end

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
                 'atx-headers')
               .gsub(/__TOC__/, "* ToC\n{:toc}\n\n")
               .gsub(/^#/, '##')
               # PandocRuby.mediawiki(wikitext).to_markdown_github('atx-headers')
             else
               # wikitext
               # wiki_html = WikiCloth::Parser.new(data: wikitext).to_html

               # PandocRuby.convert(
               # wiki_html, :s, {
               # from: :html,
               # to: :markdown_github
               # },
               # 'atx-headers'
               # )

               wiki_html = WikiCloth::Parser.new(data: wikitext)
                           .to_html(noedit: true, toc_numbered: false)
                           .gsub(/<table id="toc".*\/table>/, '* ToC\\n{:toc}\\n\\n')
               # .gsub(/<table id="toc"[^table>]*table>/, "* ToC\n{:toc}\n\n")

               # .gsub(/<span class="editsection">[^span>]*<\/span>/, '')

               wiki_html = Sanitize.clean(wiki_html, sanitize_config)
                           .gsub(/<a \/>/, '')

               kd = Kramdown::Document.new(wiki_html, input: 'html').to_kramdown
               fix_links kd
             end
    rescue
      puts 'Error in conversion. Skipping to next page.'
      next
    end

    output = html
             .gsub(/\\([_#"'\$])/, '\\1')
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
      'category'      => category_match || category_dirs,
      'authors'       => authors.join(', '),
      'wiki_category' => category,
      'wiki_title'    => title,
      # "wiki_id"       => id
    }.select { |_, val| !val.nil? }.to_yaml

    complete = "#{frontmatter}---\n\n# #{frontmatter['title']}\n\n#{output}"

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

    if wikitext.match(/^#REDIRECT/) || wikitext.strip.empty?
      puts "REDIRECTED! #{title} => #{redirect[title]}"
      begin
        File.delete "#{path}/#{full_file}"
      rescue
        puts 'Error deleting file'
      end
    else
      begin
        File.write "#{path}/#{full_file}", complete
      rescue
        puts 'Error writing file!'
      end
    end

    unless title.match(/^Created page with/) && redirect[title]
      git_author = wiki_author[username.downcase]
      git_name = git_author.nil? ? username.downcase : (git_author[:name] || username.downcase)
      git_name.gsub(/"/, "'")
      git_email = git_author.nil? ? "#{username.downcase}@wiki.conversion" : git_author[:email]
      git_comment = comment.strip.empty? ? 'Updated' : comment.gsub(/"/, "'")

      begin
        # out = system 'cd ', path,
        # ' && git add * && git commit -a --author="', git_name,
        # ' <', git_email, '>"',
        # ' -- date="', timestamp, '" ',
        # '-m "', git_comment, '" && cd -'

        # git.add(all: true)

        # git_out = git.commit_all(git_comment,
        # author: "#{git_name} <#{git_email}>",
        # author_date: timestamp,
        # commiter_date: timestamp,
        # date: timestamp)

        # git_prefix = [' --git-dir="', path, '/.git" --work-tree="', path, "'"]
        git_prefix = "cd #{path} && git --git-dir='#{path}/.git' --work-tree='#{path}'"
        git_postfix = " && cd - "

        # out_add = IO.popen ['git', 'add', ' *'] + git_prefix

        # out = IO.popen ['git', 'commit', ' -a'] +
                       # git_prefix +
                       # ['--author="', git_name,
                        # ' <', git_email, '>"',
                        # ' -- date="', timestamp, '" ',
                        # '-m "', git_comment, '" && cd -']

        out_add = `#{git_prefix} add * #{git_postfix}`

        out = `#{git_prefix} commit -a --author="#{git_name} <#{git_email}>" --date="#{timestamp}" -m "#{git_comment}" #{git_postfix}`

        puts out_add ? 'ADD SUCEESS' : 'ADD FAIL'
        puts out ? 'SUCEESS' : 'FAIL'
      rescue
        puts "Error committing! #{out} :: #{out_add}"
      end
    end
  end
end

File.write 'revisions.yaml', revision.to_yaml
File.write '_redirects.yaml', redirect.to_yaml
