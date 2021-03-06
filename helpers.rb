require 'bcrypt'
require 'gettext'
require 'rack/csrf'

include GetText
bindtextdomain 'mdwiki', path: './locale'

def hash_password pw
	BCrypt::Password.create pw
end


def read_users
	if ENV['RACK_ENV'] == 'test'
		return {'test' => '$2a$10$fPwp9rZks7diZ4lIL8Xsw.Hees3CP9URSlmBsJz3NphiZr9F4P8am'}
	end

	unless File.exists? 'users'
		# TODO: multiline gettext?
		puts 'Error: file ./users not found; you need to create this file and add least one user'
		puts 'The format is:'
		puts 'username:::password'
		puts ''
		puts 'install.rb can also create users for you'
		exit(1)
	end

	users = {}
	File.open('users', 'r').readlines.each do |line|
		line = line.chomp.split ':::'
		valid = valid_username? line[0]	
		unless valid == true
			puts valid
			exit 1
		end

		users[line[0]] = line[1]
	end

	return users
end


def valid_username? user
	# We do this because we add the username to shell commands in vcs.rb
	return _('Usernames are restricted to \w (a-zA-Z0-9_])') unless user.match(/^\w*$/)
	# Be conservative for safety
	return _('Maximum length is 32 characters') unless user.length < 33
	return true
end


def current_user
	request.env['REMOTE_USER']
end


def previous_page
	session[:previous] || '/'
end


# {
#	dir1: {
#		level: 2,
#		fileS: [file1, file2],
#	},
#	dir2: {
#		level: 2,
#		fileS: [file1, file2],
#	}
# }
def get_listing path
	dirs = {
		path.gsub(/\/+/, '/').sub(/^#{PATH_DATA}/, '') => {
			level: 0,
			files: [],
		}
	}
	files = []

	last_dir = []
	Dir.glob("#{path}/**/*").sort.each do |f|
		if File.directory?(f)
			# Dir.glob doesn't traverse symlinks :-(
			if File.symlink?(f)
				files += Dir.glob("#{f}/**/*")
					.select { |f2| f2.end_with?('.markdown') || f2.end_with?('.md') }
					.map { |f2| f2.gsub(/\/+/, '/').sub(/^#{PATH_DATA}/, '') }
			end

			f = f.gsub(/\/+/, '/').sub(/^#{PATH_DATA}/, '')
			level = f.split('/')[1..-1]
				.map.with_index { |part, i| last_dir[i] == part }
				.compact.length
			last_dir = f.split('/')[1..-1]

			dirs[f] = {
				level: level,
				files: [],
			}
		elsif f.end_with?('.markdown') || f.end_with?('.md')
			files << f.gsub(/\/+/, '/').sub(/^#{PATH_DATA}/, '')
		end
	end
	files.each { |f| dirs[File.dirname(f)][:files] << f }

	# Don't include the current dir if there are no files
	p = path.gsub(/\/+/, '/').sub(/^#{PATH_DATA}/, '')
	dirs = dirs.reject { |k, v| k == p && v.length == 0 }

	return dirs
end


# TODO: This fails for files that start with data
def path_or_uri_to_title path
	return '/' + path
		.sub(/^#{PATH_DATA}\/?/, '')
		.sub(/^[.\/]?data\/?/, '')
		.sub(/^\/*/, '')
		.sub(/\.(markdown|md)$/, '')
		.gsub('_', ' ')
end


def user_input_to_path filename, dir, is_dir=false
	unless is_dir
		filename += '.markdown' unless filename.end_with?('.markdown') || filename.end_with?('.md')
	end

	dir = "#{PATH_DATA}/#{dir}" unless dir.start_with? PATH_DATA

	full_path = File.expand_path "#{dir}/#{filename}".gsub(/\s/, '_').gsub(/\/+/, '/')
	full_path = "#{PATH_DATA}/#{File.basename full_path}" unless full_path.start_with? PATH_DATA

	return [full_path, path_to_url(full_path)]
end


def path_to_url path
	path.sub(/^#{PATH_DATA}/, '')
end


def e str
	Rack::Utils.escape_html str.to_s
end


def flash m, type=:success
	session[:flash] = [] if session[:flash].nil?
	session[:flash] << [m, type] unless session[:flash].include? [m, type]
end


def sanitize_page page
	page += "\n" unless page.end_with? "\n"
	return page.gsub "\r\n", "\n"
end


def hash_page str, path=nil
	d = Digest::SHA256.new
	d.update str.nil? ? File.open(path, 'r').read : str
	return d.hexdigest
end


# File IO operations with error handling; unfortunatly the errors that Ruby
# gives us are not always the best errors...
module FileIO
	class Error < Exception; end

	def self.catch
		# TODO: there are more errno's to handle
		# open(2), write(2), rmdir(2), unlink(2)
		begin
			yield
		rescue Errno::EACCES
			raise FileIO::Error, _('Permission denied') + ' (EACCESS)'
		rescue Errno::ENOTEMPTY
			raise FileIO::Error, _('Directory not empty') + ' (ENOTEMPTY)'
		rescue Errno::EEXIST
			raise FileIO::Error, _('Already exists') + ' (EEXIST)'
		rescue Errno::ENOENT
			raise FileIO::Error, _('No such file or directory') + ' (ENOENT)'
		end
	end


	def self.rename src, dst; self.catch { File.rename src, dst } end
	def self.copy src, dst; self.catch { FileUtils.cp src, dst} end
	def self.unlink path; self.catch { File.unlink path } end
	def self.rmdir path; self.catch { Dir.rmdir path } end
	def self.touch path; self.catch { FileUtils.touch path } end
	def self.write path, data; self.catch { File.open(path, 'w+') { |fp| fp.write data } } end
	def self.mkdir path; self.catch { FileUtils.mkdir_p path } end
end
