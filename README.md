# mw2md - MediaWiki to Markdown

Have data stuck in MediaWiki, but you'd really want a simple static site?

Never fear! `mw2md` is here for you!

It will convert a MediaWiki XML dump to a git repo full of Markdown files.

_Note: mw2md does not alter links contained within documents. You'll need to handle that yourself, either with httpd redirects or with some code in your site builder. (Or you could tinker with the code and submit a patch to enable link rewriting.)_

## Installation

### Pandoc

As Fedora 21, RHEL 7.x, and CentOS 7.x (and below) have a buggy version of
Pandoc, you'll need to upgrade. Thankfully, there's a copr perfect for this.

<https://copr.fedoraproject.org/coprs/petersen/pandoc/>

```
sudo yum copr enable petersen/pandoc
sudo yum install pandoc
```

### Ruby & Bundler

```
sudo yum install ruby rubygems-devel rubygem-bundler
```

### Bundle install

```
bundle install
```

## Usage

1. Copy your XML dump to this repo as `dump.xml`
2. Copy your user info as a CSV file and call it `authors.csv`
3. Edit `config.yml` and add special rewrite rules for your site
4. Run the convert script

    ```
    ./convert.rb
    ```

5. Wait
6. Check your output directory (in `/tmp/mw2md-output` by default)
7. Repeat steps 3 - 6 when necessary

Note: As-is, you'll need to nuke the output directory before running again
(right before step 4), else you'll wind up with duplicated history.
